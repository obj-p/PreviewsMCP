//===-- ObjCSelrefPlugin.cpp - JITLink ObjC selref uniquing plugin -*- C++ -*-===//
//
// See ObjCSelrefPlugin.hpp for rationale.
//
// Implementation notes
// --------------------
// * Section name in the JITLink LinkGraph is the canonical Mach-O
//   "__SEG,__sect" form. arm64 Swift output puts selrefs in
//   __DATA,__objc_selrefs and the C-strings they reference in
//   __TEXT,__objc_methname.
// * Each selref slot is a single 8-byte pointer. The relocation is a
//   plain Pointer64 (Mach-O UNSIGND); JITLink represents it as a
//   single edge per slot whose Target is a symbol anchored in the
//   __objc_methname block at the C-string's offset.
// * Strategy: rewrite the edge to point at an Absolute symbol whose
//   address is `sel_registerName(cstr)`. We keep one absolute symbol
//   per unique selector name across the link, both to dedupe and
//   because LinkGraph::addAbsoluteSymbol with global scope requires
//   uniqueness.
// * Pass placement: PostPrunePasses. The link graph still has its
//   original addresses (we don't need final ones); we only mutate
//   edge targets, which any later pass (memory allocation, fixup)
//   handles correctly.
//
//===----------------------------------------------------------------------===//

#include "ObjCSelrefPlugin.hpp"

#include "llvm/ADT/StringRef.h"
#include "llvm/ExecutionEngine/JITLink/JITLink.h"
#include "llvm/ExecutionEngine/Orc/ExecutorProcessControl.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdio>
#include <cstring>
#include <objc/runtime.h>
#include <string>
#include <unordered_map>

using namespace llvm;
using namespace llvm::jitlink;
using namespace llvm::orc;

namespace previewsvm {

namespace {

constexpr StringRef SelrefsSectionName = "__DATA,__objc_selrefs";
constexpr StringRef MethnameSectionName = "__TEXT,__objc_methname";

// Read a NUL-terminated C-string from the given block starting at
// the given offset. Returns the string view (not including the NUL).
// Returns std::nullopt if the block has no content or the offset is
// out of range.
std::optional<StringRef>
readCStringFromBlock(const Block &B, size_t Offset) {
    if (B.isZeroFill())
        return std::nullopt;
    ArrayRef<char> Content = B.getContent();
    if (Offset >= Content.size())
        return std::nullopt;
    const char *Start = Content.data() + Offset;
    size_t MaxLen = Content.size() - Offset;
    size_t Len = ::strnlen(Start, MaxLen);
    if (Len == MaxLen) // unterminated — skip rather than misregister
        return std::nullopt;
    return StringRef(Start, Len);
}

} // anonymous namespace

void ObjCSelrefPlugin::modifyPassConfig(
    MaterializationResponsibility &MR,
    LinkGraph &G,
    PassConfiguration &Config) {

    bool Verbose = this->Verbose;

    Config.PostPrunePasses.push_back([Verbose](LinkGraph &G) -> Error {
        Section *Selrefs = G.findSectionByName(SelrefsSectionName);
        if (!Selrefs) {
            if (Verbose)
                fprintf(stderr,
                        "[objc-selref-plugin] graph %s: no %s section, "
                        "nothing to do\n",
                        G.getName().c_str(),
                        SelrefsSectionName.data());
            return Error::success();
        }

        // Dedupe absolute symbols per link by selector name. The
        // LinkGraph requires unique global-scope absolute names, so
        // we reuse a single absolute per selector across multiple
        // selref slots within the same graph.
        std::unordered_map<std::string, Symbol *> AbsBySelectorName;

        size_t Rewritten = 0;
        size_t Skipped = 0;

        for (Block *SelrefBlk : Selrefs->blocks()) {
            for (Edge &E : SelrefBlk->edges()) {
                Symbol &Target = E.getTarget();
                if (!Target.isDefined()) {
                    // Defensive: a selref edge should target a
                    // defined methname symbol. If it doesn't (e.g.
                    // someone retargeted before us), skip.
                    ++Skipped;
                    continue;
                }
                Section &TgtSection = Target.getSection();
                if (TgtSection.getName() != MethnameSectionName) {
                    ++Skipped;
                    continue;
                }

                size_t OffsetInBlock =
                    Target.getOffset() +
                    static_cast<size_t>(E.getAddend());
                auto MaybeName =
                    readCStringFromBlock(Target.getBlock(), OffsetInBlock);
                if (!MaybeName) {
                    if (Verbose)
                        fprintf(stderr,
                                "[objc-selref-plugin] graph %s: "
                                "could not read selector cstring at "
                                "block %p offset %zu\n",
                                G.getName().c_str(),
                                (void *)&Target.getBlock(),
                                OffsetInBlock);
                    ++Skipped;
                    continue;
                }

                std::string SelName = MaybeName->str();

                Symbol *AbsSym = nullptr;
                if (auto It = AbsBySelectorName.find(SelName);
                    It != AbsBySelectorName.end()) {
                    AbsSym = It->second;
                } else {
                    // Register with libobjc and reify as an Absolute
                    // symbol in the graph.
                    SEL Sel = ::sel_registerName(SelName.c_str());
                    ExecutorAddr SelAddr(
                        reinterpret_cast<uint64_t>((void *)Sel));

                    // Synthesise a unique internal name so the graph
                    // doesn't reject duplicates across selrefs that
                    // happen to share the same selector across
                    // different links. We use a "local" scope absolute
                    // so this name isn't visible outside the graph.
                    std::string AbsName =
                        "$__objc_sel_abs$" + SelName;
                    AbsSym = &G.addAbsoluteSymbol(
                        AbsName,
                        SelAddr,
                        /*Size=*/8,
                        Linkage::Strong,
                        Scope::Local,
                        /*IsLive=*/true);
                    AbsBySelectorName.emplace(std::move(SelName), AbsSym);

                    if (Verbose)
                        fprintf(stderr,
                                "[objc-selref-plugin] graph %s: "
                                "registered sel %s -> %p\n",
                                G.getName().c_str(),
                                MaybeName->str().c_str(),
                                (void *)Sel);
                }

                // Retarget the edge to the canonical SEL absolute.
                // Addend goes to zero — the absolute's address is
                // already the SEL value we want.
                E.setTarget(*AbsSym);
                E.setAddend(0);
                ++Rewritten;
            }
        }

        if (Verbose)
            fprintf(stderr,
                    "[objc-selref-plugin] graph %s: rewrote %zu "
                    "selref edge(s), skipped %zu, %zu unique selector(s)\n",
                    G.getName().c_str(), Rewritten, Skipped,
                    AbsBySelectorName.size());

        return Error::success();
    });
}

} // namespace previewsvm

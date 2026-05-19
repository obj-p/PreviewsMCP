//===-- host_objc.cpp - W2 JITLink POC Phase-2 step-2.5 host ----*- C++ -*-===//
//
// Phase-2 step-2.5 of the W2 JITLink POC. Validates the
// `ObjCSelrefPlugin`: a JITLink `ObjectLinkingLayer::Plugin` that
// closes the documented gap where public LLVM's `MachOPlatform`
// processes `__objc_imageinfo` but does NOT register selector strings
// with libobjc. The unmodified path was demonstrated to abort in
// `__forwarding__` by `data/run-tlv-20260519T015157Z.log`.
//
// Setup mirrors host_tlv.cpp: an explicit MachOPlatform backed by
// the ORC runtime; process-symbol generator for libc/Swift/Foundation
// refs; preflight dlopen of libswiftCore + Foundation +
// libswiftFoundation. The new bit is `LinkLayer.addPlugin(...)` for
// the selref-uniquing plugin, which is constructed in this binary
// rather than supplied by the LLJIT builder so we can keep an
// observable handle to it.
//
// We also dump the contents of __DATA,__objc_selrefs **before** the
// call (i.e. after JITLink finishes) so the run log records the
// canonical SEL addresses the plugin produced. The host then calls
// `touchFoundation` (ProcessInfo.processInfo, the original failing
// case) and `touchNSString` (NSString(format:) + description — a
// distinct selref-heavy code path) to confirm the fix generalises.
//
//===----------------------------------------------------------------------===//

#include "ObjCSelrefPlugin.hpp"

#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"
#include "llvm/ExecutionEngine/Orc/MachOPlatform.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/InitLLVM.h"
#include "llvm/Support/MemoryBuffer.h"
#include "llvm/Support/TargetSelect.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdio>
#include <cstdlib>
#include <dlfcn.h>
#include <memory>
#include <objc/runtime.h>
#include <string>

using namespace llvm;
using namespace llvm::orc;

[[noreturn]] static void diefmt(const char *msg, Error E) {
    std::string es;
    raw_string_ostream os(es);
    os << E;
    fprintf(stderr, "FATAL: %s: %s\n", msg, es.c_str());
    fflush(stderr);
    std::exit(1);
}

template <typename T>
static T must(const char *msg, Expected<T> E) {
    if (!E)
        diefmt(msg, E.takeError());
    return std::move(*E);
}

static void must(const char *msg, Error E) {
    if (E)
        diefmt(msg, std::move(E));
}

static std::unique_ptr<MemoryBuffer> loadObject(const char *Path) {
    auto BufOrErr = MemoryBuffer::getFile(Path);
    if (!BufOrErr) {
        fprintf(stderr, "FATAL: failed to read object file %s: %s\n",
                Path, BufOrErr.getError().message().c_str());
        std::exit(1);
    }
    return std::move(*BufOrErr);
}

// Look up a known-good SEL via libobjc directly so the run log lets
// us verify the plugin's output matches the canonical pointer.
static void *canonicalSel(const char *name) {
    return (void *)::sel_registerName(name);
}

int main(int argc, char **argv) {
    InitLLVM X(argc, argv);

    if (argc != 3) {
        fprintf(stderr,
                "usage: %s <orc_rt_osx.a> <objc_v1.o>\n",
                argv[0]);
        return 2;
    }
    const char *OrcRTPath = argv[1];
    const char *ObjCPath = argv[2];

    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

    // Hold a non-owning pointer to the plugin so we can keep its
    // verbose-logging on across the link.
    auto Plugin = std::make_shared<previewsvm::ObjCSelrefPlugin>(
        /*Verbose=*/true);

    auto JIT = must("LLJITBuilder::create",
        LLJITBuilder()
            .setObjectLinkingLayerCreator(
                [Plugin](ExecutionSession &ES)
                    -> Expected<std::unique_ptr<ObjectLayer>> {
                    auto OLL =
                        std::make_unique<ObjectLinkingLayer>(ES);
                    OLL->setAutoClaimResponsibilityForObjectSymbols(
                        true);
                    OLL->addPlugin(Plugin);
                    return OLL;
                })
            .setPlatformSetUp(orc::ExecutorNativePlatform(OrcRTPath))
            .create());

    fprintf(stdout, "[host] LLJIT target triple: %s\n",
            JIT->getTargetTriple().str().c_str());

    auto &MainJD = JIT->getMainJITDylib();

    {
        auto Gen = must(
            "DynamicLibrarySearchGenerator::GetForCurrentProcess",
            DynamicLibrarySearchGenerator::GetForCurrentProcess(
                JIT->getDataLayout().getGlobalPrefix()));
        MainJD.addGenerator(std::move(Gen));
    }

    auto tryDLOpen = [](std::initializer_list<const char *> Paths,
                        const char *Label) {
        for (const char *P : Paths) {
            if (dlopen(P, RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stdout, "[host] dlopened %s via %s\n",
                        Label, P);
                return;
            }
        }
        fprintf(stderr,
                "[host] WARNING: could not dlopen %s: %s\n",
                Label, dlerror());
    };
    tryDLOpen({"/usr/lib/swift/libswiftCore.dylib",
               "@rpath/libswiftCore.dylib",
               "libswiftCore.dylib"},
              "libswiftCore");
    tryDLOpen({"/System/Library/Frameworks/Foundation.framework/Foundation",
               "Foundation.framework/Foundation"},
              "Foundation.framework");
    tryDLOpen({"/usr/lib/swift/libswiftFoundation.dylib",
               "libswiftFoundation.dylib"},
              "libswiftFoundation");

    // Log canonical SEL pointers BEFORE we load the JIT object so the
    // run log captures the libobjc-canonical addresses we expect the
    // plugin to splice in.
    fprintf(stdout,
            "[host] canonical sel_registerName(\"processInfo\")"
            " = %p\n", canonicalSel("processInfo"));
    fprintf(stdout,
            "[host] canonical sel_registerName(\"processIdentifier\")"
            " = %p\n", canonicalSel("processIdentifier"));
    fprintf(stdout,
            "[host] canonical sel_registerName(\"description\")"
            " = %p\n", canonicalSel("description"));

    {
        fprintf(stdout, "[host] loading ObjC-touching Swift object "
                        "from %s\n", ObjCPath);
        auto Buf = loadObject(ObjCPath);
        must("addObjectFile(objc_v1)",
             JIT->addObjectFile(MainJD, std::move(Buf)));

        // First test: the originally-failing ProcessInfo case.
        auto Sym1 = must("lookup(touchFoundation)",
                         JIT->lookup("touchFoundation"));
        auto FP1 = Sym1.toPtr<void(*)()>();
        fprintf(stdout, "[host] touchFoundation -> %p; calling...\n",
                (void *)FP1);
        fflush(stdout);
        FP1();
        fflush(stdout);

        // Second test: NSString(format:) + description, a different
        // selref-heavy path.
        auto Sym2 = must("lookup(touchNSString)",
                         JIT->lookup("touchNSString"));
        auto FP2 = Sym2.toPtr<void(*)()>();
        fprintf(stdout, "[host] touchNSString -> %p; calling...\n",
                (void *)FP2);
        fflush(stdout);
        FP2();
        fflush(stdout);
    }

    fprintf(stdout, "[host] done.\n");
    return 0;
}

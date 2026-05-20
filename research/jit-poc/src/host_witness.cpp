//===-- host_witness.cpp - W2 JITLink POC Phase-2 step-1 host ---*- C++ -*-===//
//
// Phase-2 step-1 of the W2 JITLink POC. Demonstrates that LLVM ORC +
// JITLink can ingest Swift objects whose call sites dispatch through a
// **protocol witness table** — the closest analogue to "hot-reload the
// `body` of a SwiftUI View" and the most directly relevant exercise
// for W3's eventual patch-point set.
//
// What this harness does:
//   1. Same LLJIT + ObjectLinkingLayer setup as host.cpp.
//   2. Adds the host process's symbol table as a definition source
//      and eagerly dlopens libswiftCore so Swift stdlib symbols
//      resolve (same as Phase 1).
//   3. Loads `Greeter.o` into MainJD. That object holds the shared
//      protocol descriptor `$s7Greeter0A0_pMp` and is *referenced*
//      from both v1 and v2 (so a single protocol identity exists
//      across both versions).
//   4. Loads `greeter_v1.o` into JD "v1" (link order: v1 -> Main).
//      Looks up `makeGreeting`, calls it — expects `hello from v1`.
//      The v1 source uses `let g: any Greeter = DefaultGreeter()` so
//      `g.greet()` dispatches through the witness table at runtime.
//   5. Loads `greeter_v2.o` into JD "v2" (link order: v2 -> Main).
//      Looks up `makeGreeting` *in V2JD*, calls it — expects
//      `hello from v2`. Same protocol descriptor as v1, but a fresh
//      conformance/witness-table chain.
//
// Stretch goal (in this same harness): see runStretchGoal() below.
//
//===----------------------------------------------------------------------===//

#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ExecutionUtils.h"
#include "llvm/ExecutionEngine/Orc/LLJIT.h"
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
static T &must(const char *msg, Expected<T &> E) {
    if (!E)
        diefmt(msg, E.takeError());
    return *E;
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

int main(int argc, char **argv) {
    InitLLVM X(argc, argv);

    if (argc != 4 && argc != 6) {
        fprintf(stderr,
                "usage: %s <Greeter.o> <greeter_v1.o> <greeter_v2.o>"
                " [<conform_v1.o> <conform_v2.o>]\n", argv[0]);
        return 2;
    }
    const char *GreeterPath = argv[1];
    const char *V1Path = argv[2];
    const char *V2Path = argv[3];
    const char *ConformV1Path = (argc == 6) ? argv[4] : nullptr;
    const char *ConformV2Path = (argc == 6) ? argv[5] : nullptr;

    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

    auto JIT = must("LLJITBuilder::create",
        LLJITBuilder()
            .setObjectLinkingLayerCreator(
                [](ExecutionSession &ES)
                    -> Expected<std::unique_ptr<ObjectLayer>> {
                    return std::make_unique<ObjectLinkingLayer>(ES);
                })
            .create());

    fprintf(stdout, "[host] LLJIT target triple: %s\n",
            JIT->getTargetTriple().str().c_str());

    // Process-symbol resolution (so Swift stdlib calls resolve to the
    // running process's loaded libswiftCore + libSystem).
    {
        auto Gen = must(
            "DynamicLibrarySearchGenerator::GetForCurrentProcess",
            DynamicLibrarySearchGenerator::GetForCurrentProcess(
                JIT->getDataLayout().getGlobalPrefix()));
        JIT->getMainJITDylib().addGenerator(std::move(Gen));
    }

    // Eagerly pull in libswiftCore so its symbols are visible to the
    // process-symbol generator above.
    {
        const char *CandidatePaths[] = {
            "/usr/lib/swift/libswiftCore.dylib",
            "@rpath/libswiftCore.dylib",
            "libswiftCore.dylib",
            nullptr,
        };
        void *Handle = nullptr;
        for (const char **P = CandidatePaths; *P; ++P) {
            Handle = dlopen(*P, RTLD_NOW | RTLD_GLOBAL);
            if (Handle) {
                fprintf(stdout,
                        "[host] dlopened libswiftCore via %s\n", *P);
                break;
            }
        }
        if (!Handle) {
            fprintf(stderr,
                    "[host] WARNING: could not dlopen libswiftCore.dylib"
                    " — JITLink symbol resolution will likely fail "
                    "on Swift runtime refs. dlerror: %s\n", dlerror());
        }
    }

    // -------- Phase 2 step 1, stage A: load shared protocol --------
    //
    // Greeter.o holds the protocol descriptor and module-init
    // boilerplate. It must be loaded BEFORE v1/v2 because their
    // objects reference its symbols as externals.
    {
        fprintf(stdout, "[host] loading Greeter object from %s\n",
                GreeterPath);
        auto Buf = loadObject(GreeterPath);
        must("addObjectFile(Greeter)",
             JIT->addObjectFile(JIT->getMainJITDylib(), std::move(Buf)));
    }

    // Helper to call `makeGreeting` looked up in a specific JD. The
    // function is declared `@_cdecl("makeGreeting")` returning Int —
    // on arm64-darwin that's `long` (8 bytes). We don't care about
    // the return value other than as a smoke signal.
    auto callMakeGreetingIn = [&](JITDylib &JD, const char *Label) {
        auto &ES = JIT->getExecutionSession();
        auto MangledName = ES.intern(
            JIT->getDataLayout().getGlobalPrefix() == '\0'
                ? "makeGreeting"
                : "_makeGreeting");
        auto SymOrErr = ES.lookup(
            {{&JD, JITDylibLookupFlags::MatchAllSymbols}},
            MangledName);
        auto Sym = must("ES.lookup(_makeGreeting)", std::move(SymOrErr));
        auto FP = Sym.getAddress().toPtr<long(*)()>();
        fprintf(stdout, "[host] %s makeGreeting resolved to %p; calling...\n",
                Label, (void *)FP);
        fflush(stdout);
        long rc = FP();
        fflush(stdout);
        fprintf(stdout, "[host] %s makeGreeting returned %ld\n", Label, rc);
    };

    // -------- Phase 2 step 1, stage B: load v1, dispatch ----------
    //
    // V1JD's link order is [V1JD, MainJD] so externals (the Greeter
    // protocol descriptor, Swift stdlib symbols via the process-symbol
    // generator on MainJD) resolve back through MainJD.
    {
        fprintf(stdout, "[host] loading v1 object from %s\n", V1Path);
        auto &V1JD = must("createJITDylib(v1)",
                          JIT->createJITDylib("v1"));
        V1JD.setLinkOrder({{&V1JD, JITDylibLookupFlags::MatchAllSymbols},
                           {&JIT->getMainJITDylib(),
                            JITDylibLookupFlags::MatchAllSymbols}},
                          /*LinkAgainstThisJITDylibFirst=*/false);
        auto Buf = loadObject(V1Path);
        must("addObjectFile(v1)",
             JIT->addObjectFile(V1JD, std::move(Buf)));
        callMakeGreetingIn(V1JD, "v1");
    }

    // -------- Phase 2 step 1, stage C: load v2, dispatch ----------
    //
    // Same shape as V1JD. Note we deliberately keep V1JD around — we
    // are NOT removing v1's definitions, we're adding v2 in a separate
    // JD and looking up *there*. That mirrors Phase 1's pattern.
    {
        fprintf(stdout, "[host] loading v2 object from %s\n", V2Path);
        auto &V2JD = must("createJITDylib(v2)",
                          JIT->createJITDylib("v2"));
        V2JD.setLinkOrder({{&V2JD, JITDylibLookupFlags::MatchAllSymbols},
                           {&JIT->getMainJITDylib(),
                            JITDylibLookupFlags::MatchAllSymbols}},
                          /*LinkAgainstThisJITDylibFirst=*/false);
        auto Buf = loadObject(V2Path);
        must("addObjectFile(v2)",
             JIT->addObjectFile(V2JD, std::move(Buf)));
        callMakeGreetingIn(V2JD, "v2");
    }

    // -------- Stretch goal: cross-JITDylib conformance "patch" -----
    //
    // Question: if we load conform_v1.o (which exports a
    // DefaultGreeter conformance whose witness table's `greet` slot
    // points at v1's body) into MainJD, materialize+call
    // makeGreeting, and THEN load conform_v2.o (identical symbol
    // names, different witness body) into a separate JD that's
    // ordered ahead of MainJD in lookups — does v1's makeGreeting
    // pointer pick up v2's witness body on the next call?
    //
    // Predicted answer: no. JITLink resolves relocations at link
    // time, not at lookup time. v1's DefaultGreeter type metadata
    // has its witness-table pointer patched once during link, and
    // it points at v1's witness-table data. A subsequent JD with
    // different bytes doesn't retroactively edit those pointers.
    //
    // What we DO expect to work: a fresh lookup of makeGreeting via
    // V2JD (or via a JD whose link order prefers V2JD) returns the
    // v2 makeGreeting entry, which links against v2's
    // type-metadata/witness-table — same as Stage B/C above with
    // matching module names rather than distinct ones.
    if (ConformV1Path && ConformV2Path) {
        fprintf(stdout, "\n[host] === stretch goal ===\n");
        fprintf(stdout, "[host] loading conform_v1 into MainJD: %s\n",
                ConformV1Path);
        auto Buf1 = loadObject(ConformV1Path);
        must("addObjectFile(conform_v1 -> MainJD)",
             JIT->addObjectFile(JIT->getMainJITDylib(),
                                std::move(Buf1)));

        auto &ES = JIT->getExecutionSession();
        auto MangledMG = ES.intern(
            JIT->getDataLayout().getGlobalPrefix() == '\0'
                ? "makeGreeting"
                : "_makeGreeting");

        // Look up conform_v1's makeGreeting via MainJD (its home).
        // Save the function pointer so we can call it again AFTER
        // adding conform_v2 to a different JD.
        auto V1SymOrErr = ES.lookup(
            {{&JIT->getMainJITDylib(),
              JITDylibLookupFlags::MatchAllSymbols}},
            MangledMG);
        auto V1Sym = must("ES.lookup(_makeGreeting in MainJD pre-v2)",
                          std::move(V1SymOrErr));
        auto V1FP = V1Sym.getAddress().toPtr<long(*)()>();
        fprintf(stdout,
                "[host] stretch: pre-patch v1 makeGreeting = %p; "
                "calling...\n", (void *)V1FP);
        fflush(stdout);
        V1FP();
        fflush(stdout);

        // Now load conform_v2 into ConfV2JD, with link order
        // [ConfV2JD, MainJD]. ConfV2JD's symbols match v1's by name.
        fprintf(stdout, "[host] loading conform_v2 into ConfV2JD: %s\n",
                ConformV2Path);
        auto &ConfV2JD = must("createJITDylib(ConfV2JD)",
                              JIT->createJITDylib("ConfV2JD"));
        ConfV2JD.setLinkOrder(
            {{&ConfV2JD, JITDylibLookupFlags::MatchAllSymbols},
             {&JIT->getMainJITDylib(),
              JITDylibLookupFlags::MatchAllSymbols}},
            /*LinkAgainstThisJITDylibFirst=*/false);
        auto Buf2 = loadObject(ConformV2Path);
        must("addObjectFile(conform_v2 -> ConfV2JD)",
             JIT->addObjectFile(ConfV2JD, std::move(Buf2)));

        // Q1: re-call v1's saved function pointer. Does the dispatch
        // pick up v2's witness body? Predicted: still prints v1's.
        fprintf(stdout, "[host] stretch Q1: re-calling SAVED v1 FP "
                        "after loading conform_v2 into ConfV2JD\n");
        fflush(stdout);
        V1FP();
        fflush(stdout);

        // Q2: fresh lookup of makeGreeting in ConfV2JD. Should
        // materialize v2's makeGreeting, which calls v2's witness.
        fprintf(stdout, "[host] stretch Q2: fresh lookup of "
                        "_makeGreeting in ConfV2JD\n");
        callMakeGreetingIn(ConfV2JD, "conform_v2");

        // Q3: fresh lookup of makeGreeting via MainJD AFTER prepending
        // ConfV2JD to MainJD's link order. Predicted: still v1,
        // because MainJD's local definition already exists and
        // takes precedence over its link-order references for
        // symbols it itself defines.
        JIT->getMainJITDylib().setLinkOrder(
            {{&JIT->getMainJITDylib(),
              JITDylibLookupFlags::MatchAllSymbols},
             {&ConfV2JD, JITDylibLookupFlags::MatchAllSymbols}},
            /*LinkAgainstThisJITDylibFirst=*/false);
        auto Q3SymOrErr = ES.lookup(
            {{&JIT->getMainJITDylib(),
              JITDylibLookupFlags::MatchAllSymbols}},
            MangledMG);
        auto Q3Sym = must("ES.lookup(_makeGreeting in MainJD post-v2)",
                          std::move(Q3SymOrErr));
        auto Q3FP = Q3Sym.getAddress().toPtr<long(*)()>();
        fprintf(stdout,
                "[host] stretch Q3: post-patch MainJD makeGreeting = %p"
                " (was %p); calling...\n",
                (void *)Q3FP, (void *)V1FP);
        fflush(stdout);
        Q3FP();
        fflush(stdout);

        fprintf(stdout, "[host] === stretch goal end ===\n\n");
    }

    fprintf(stdout, "[host] done.\n");
    return 0;
}

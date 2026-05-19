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

    if (argc != 4) {
        fprintf(stderr,
                "usage: %s <Greeter.o> <greeter_v1.o> <greeter_v2.o>\n",
                argv[0]);
        return 2;
    }
    const char *GreeterPath = argv[1];
    const char *V1Path = argv[2];
    const char *V2Path = argv[3];

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

    fprintf(stdout, "[host] done.\n");
    return 0;
}

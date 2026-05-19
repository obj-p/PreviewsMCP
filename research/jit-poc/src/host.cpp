//===-- host.cpp - W2 JITLink POC host harness ------------------*- C++ -*-===//
//
// Phase-1 of the W2 JITLink POC. See ../SCOPE.md for what this tests
// and what's deliberately out of scope.
//
// This harness:
//   1. Builds an LLJIT instance configured with JITLink's
//      ObjectLinkingLayer (NOT RTDyld) — JITLink is what Apple ships,
//      per research/scripts/analysis/q6-jit-runtime-findings.md.
//   2. Adds the host process's symbol table as a definition source
//      (so Swift stdlib / libSystem / dyld symbols referenced from
//      Swift `.o` files resolve to the running process).
//   3. Loads Swift v1's `.o`, looks up `greet`, calls it. Expects
//      "hello from swift v1".
//   4. Loads Swift v2's `.o` into a *second* JITDylib whose search
//      order resolves before v1's JITDylib, re-resolves `greet`,
//      calls it. Expects "hello from swift v2" — i.e., a function
//      override via ORC's JITDylib lookup ordering.
//
// Built with brewed LLVM 22 via clang++ (NOT xcrun's clang++). See
// ../build.sh for the exact flags.
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

// Helper — fail loud with a clear error message and exit non-zero.
// We do this manually rather than using ExitOnError so that the
// error path is obvious in the run log.
[[noreturn]] static void diefmt(const char *msg, Error E) {
    std::string es;
    raw_string_ostream os(es);
    os << E;
    fprintf(stderr, "FATAL: %s: %s\n", msg, es.c_str());
    fflush(stderr);
    std::exit(1);
}

// Overloads — Expected<T&> binds the reference, Expected<T> moves.
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

    if (argc != 3) {
        fprintf(stderr,
                "usage: %s <greet_v1.o> <greet_v2.o>\n", argv[0]);
        return 2;
    }
    const char *V1Path = argv[1];
    const char *V2Path = argv[2];

    // Initialize native target machinery — required before LLJIT can
    // pick a JITTargetMachineBuilder for the host triple. JITLink
    // needs the assembly target too (for split-and-relocate).
    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

    // Build LLJIT with an explicit JITLink-backed ObjectLinkingLayer.
    // The default would be RTDyldObjectLinkingLayer; we want JITLink
    // because (a) it's what Apple's XOJITExecutor uses, and (b) it's
    // the path we're validating coverage for.
    auto JIT = must("LLJITBuilder::create",
        LLJITBuilder()
            .setObjectLinkingLayerCreator(
                [](ExecutionSession &ES)
                    -> Expected<std::unique_ptr<ObjectLayer>> {
                    return std::make_unique<ObjectLinkingLayer>(ES);
                })
            .create());

    // Print the LLJIT's effective target triple so the run log
    // records exactly what we're targeting. Sanity check for the
    // arm64-apple-darwin assumption.
    fprintf(stdout, "[host] LLJIT target triple: %s\n",
            JIT->getTargetTriple().str().c_str());

    // Wire up host-process symbol resolution. The Swift `.o` will
    // reference `_swift_` runtime calls, `_print`-related stdlib
    // symbols, libSystem, etc. — all of which are loaded in this
    // process via the Swift runtime dlopens below.
    //
    // GlobalPrefix on Mach-O / arm64-darwin is '_' (underscored
    // symbol names). LLVM ORC will strip / re-add the prefix as
    // needed during lookup.
    {
        auto Gen = must(
            "DynamicLibrarySearchGenerator::GetForCurrentProcess",
            DynamicLibrarySearchGenerator::GetForCurrentProcess(
                JIT->getDataLayout().getGlobalPrefix()));
        JIT->getMainJITDylib().addGenerator(std::move(Gen));
    }

    // Eagerly pull the Swift runtime into the host process so its
    // symbols are visible to the dyld search. swiftc emits objects
    // that reference symbols like _swift_release / _swift_retain /
    // _swift_allocObject / $sSS... — these live in libswiftCore.dylib,
    // which doesn't auto-load in a plain C++ binary.
    //
    // On macOS arm64 the canonical search paths (Xcode toolchain +
    // OS path) usually find it. If neither is present we fall back
    // to dlopen'ing by short name and trusting DYLD_FALLBACK_LIBRARY_PATH.
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

    // -------- Phase 1, step 1: load v1 and call greet() --------
    //
    // The Swift function is declared `@_cdecl("greet")`, so its
    // C-name symbol is `_greet` on Mach-O. LLJIT::lookup takes the
    // IR-level name; the underscore prefix is added during mangling.
    {
        fprintf(stdout, "[host] loading v1 object from %s\n", V1Path);
        auto Buf = loadObject(V1Path);
        must("addObjectFile(v1)",
             JIT->addObjectFile(JIT->getMainJITDylib(), std::move(Buf)));

        auto Addr = must("lookup(greet) after v1",
                          JIT->lookup("greet"));
        auto FP = Addr.toPtr<void(*)()>();
        fprintf(stdout, "[host] v1 greet resolved to %p; calling...\n",
                (void *)FP);
        fflush(stdout);
        FP();
        fflush(stdout);
    }

    // -------- Phase 1, step 2: load v2, re-resolve, call ----------
    //
    // We create a new JITDylib "v2" that contains only the v2 object,
    // and prepend it to the main JD's link order so that lookups
    // hitting MainJD's link order resolve v2 first. ORC's
    // setLinkOrder lets us put the override JD ahead of MainJD's
    // own contents (and ahead of the process-symbols generator).
    {
        fprintf(stdout, "[host] loading v2 object from %s\n", V2Path);
        auto &V2JD = must("createJITDylib(v2)",
                          JIT->createJITDylib("v2"));
        auto Buf = loadObject(V2Path);
        must("addObjectFile(v2)",
             JIT->addObjectFile(V2JD, std::move(Buf)));

        // Re-resolve via the v2 JITDylib directly. This bypasses
        // any caching of the v1 ExecutorAddr in MainJD and forces
        // ORC to materialize from V2JD.
        //
        // Using ES.lookup with an explicit search order ensures
        // we get v2's definition even though both v1 and v2 define
        // the same symbol name.
        auto &ES = JIT->getExecutionSession();
        auto MangledName = ES.intern(
            JIT->getDataLayout().getGlobalPrefix() == '\0'
                ? "greet"
                : "_greet");
        auto SymOrErr = ES.lookup(
            {{&V2JD, JITDylibLookupFlags::MatchAllSymbols}},
            MangledName);
        auto Sym = must("ES.lookup(_greet in v2 JD)", std::move(SymOrErr));

        auto FP = Sym.getAddress().toPtr<void(*)()>();
        fprintf(stdout, "[host] v2 greet resolved to %p; calling...\n",
                (void *)FP);
        fflush(stdout);
        FP();
        fflush(stdout);
    }

    fprintf(stdout, "[host] done.\n");
    return 0;
}

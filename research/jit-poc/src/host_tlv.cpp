//===-- host_tlv.cpp - W2 JITLink POC Phase-2 step-2 host -------*- C++ -*-===//
//
// Phase-2 step-2 of the W2 JITLink POC. Tests the canonical "hard
// case" for JIT-link Mach-O on Darwin: thread-local variables and
// global initialization.
//
// What this harness validates (or documents the gap of):
//   * Mach-O TLV codegen — `__thread_vars` / `__thread_data` /
//     `_tlv_bootstrap` — linked + initialized + read correctly under
//     MachOPlatform-managed JIT-link.
//   * Swift's `swift_once`-based module-level `let` initialization —
//     `_$s..._WZ` (one-time-init function), `_$s..._Wz` (token), and
//     the `vau` (unsafe-mutable-addressor) symbol that callers use to
//     reach the storage. This is what Swift actually emits for
//     module-level state; Swift does NOT use Mach-O TLVs.
//
// KEY FINDING (recorded here before the run): a Swift `let foo = { ...
// }()` at module scope produces NO `__thread_vars` section. swiftc 6.x
// uses regular global storage + `swift_once` + addressor symbols
// instead. That's its own JIT-link exercise (different from C's TLV
// path), and we test it here too.
//
// Setup differences from host.cpp / host_witness.cpp:
//   * Builds the LLJIT with an explicit MachOPlatform configured via
//     LLJITBuilder::setPlatformSetUp(orc::ExecutorNativePlatform(...)).
//     The ORC runtime is the brewed LLVM's `liborc_rt_osx.a` (arm64
//     slice). This is required for `_tlv_bootstrap` resolution
//     because the platform installs the `tlv_bootstrap ->
//     __orc_rt_macho_tlv_get_addr` alias.
//   * PlatformJD picks up the process-symbol generator (for libc /
//     libSystem refs from the C TLV code).
//   * The TLV objects go into a separate "TLVJD" whose link order is
//     [TLVJD, PlatformJD], so refs to `_tlv_bootstrap`, `_printf`,
//     `_getpid`, and the Swift stdlib all resolve correctly.
//
// Expected output on success (printed below by main):
//   tlv c v1: incTLV -> 43
//   tlv c v1: incTLV -> 44
//   tlv c v1: peekTLV -> 44
//   tlv v1: counter=44 (pid=...)
//   computed in v1 (pid=...)
//
// If anything fails, the FATAL message + raw Error from JITLink is
// the load-bearing observation.
//
//===----------------------------------------------------------------------===//

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
                "usage: %s <orc_rt_osx.a> <tlv_c_v1.o> <tlv_v1.o>\n",
                argv[0]);
        return 2;
    }
    const char *OrcRTPath = argv[1];
    const char *CTLVPath = argv[2];
    const char *SwiftTLVPath = argv[3];

    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

    // Build LLJIT with an explicit MachOPlatform. Note that
    // ExecutorNativePlatform requires the ORC runtime path (a static
    // archive that the platform pulls symbols out of, including
    // __orc_rt_macho_tlv_get_addr to satisfy the _tlv_bootstrap
    // alias).
    auto JIT = must("LLJITBuilder::create",
        LLJITBuilder()
            .setObjectLinkingLayerCreator(
                [](ExecutionSession &ES)
                    -> Expected<std::unique_ptr<ObjectLayer>> {
                    auto OLL =
                        std::make_unique<ObjectLinkingLayer>(ES);
                    // Allow weak/duplicate definitions to coexist
                    // across objects (Swift FORCE_LOAD weak symbols
                    // and ORC runtime aliases tend to collide).
                    OLL->setAutoClaimResponsibilityForObjectSymbols(
                        true);
                    return OLL;
                })
            .setPlatformSetUp(orc::ExecutorNativePlatform(OrcRTPath))
            .create());

    fprintf(stdout, "[host] LLJIT target triple: %s\n",
            JIT->getTargetTriple().str().c_str());

    auto &MainJD = JIT->getMainJITDylib();

    // Process-symbol resolution. We attach the process-symbol
    // generator to MainJD so C runtime calls (printf, getpid) and
    // Swift stdlib symbols (swift_once, swift_beginAccess, etc.)
    // all resolve to the running process.
    {
        auto Gen = must(
            "DynamicLibrarySearchGenerator::GetForCurrentProcess",
            DynamicLibrarySearchGenerator::GetForCurrentProcess(
                JIT->getDataLayout().getGlobalPrefix()));
        MainJD.addGenerator(std::move(Gen));
    }

    // Eagerly pull in libswiftCore so the Swift TLV-via-swift_once
    // object's runtime refs resolve through the process-symbol
    // generator. Foundation is needed too because tlv_v1.swift uses
    // `ProcessInfo` — its initializer references _OBJC_CLASS_$_NSProcessInfo
    // which lives in Foundation.framework (the ObjC implementation), and
    // _$sSo13NSProcessInfoC10FoundationE etc. live in libswiftFoundation.
    auto tryDLOpen = [](std::initializer_list<const char *> Paths,
                        const char *Label) {
        for (const char *P : Paths) {
            if (void *H = dlopen(P, RTLD_NOW | RTLD_GLOBAL)) {
                fprintf(stdout, "[host] dlopened %s via %s\n", Label, P);
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

    // ------------------ load C TLV object ------------------
    //
    // tlv_c_v1.o contains `_Thread_local int tlvCounter`. The
    // expected sections are __thread_vars (descriptor) and
    // __thread_data (initial value 42). It references _tlv_bootstrap
    // as undefined; MachOPlatform aliases that to
    // __orc_rt_macho_tlv_get_addr provided by the ORC runtime.
    {
        fprintf(stdout, "[host] loading C TLV object from %s\n",
                CTLVPath);
        auto Buf = loadObject(CTLVPath);
        must("addObjectFile(tlv_c_v1)",
             JIT->addObjectFile(MainJD, std::move(Buf)));

        // First call: incTLV — should mutate from 42 -> 43.
        auto IncSym = must("lookup(incTLV)", JIT->lookup("incTLV"));
        auto IncFP = IncSym.toPtr<int(*)()>();
        fprintf(stdout, "[host] tlv c v1: incTLV -> %d\n", IncFP());
        fprintf(stdout, "[host] tlv c v1: incTLV -> %d\n", IncFP());

        auto PeekSym = must("lookup(peekTLV)", JIT->lookup("peekTLV"));
        auto PeekFP = PeekSym.toPtr<int(*)()>();
        fprintf(stdout, "[host] tlv c v1: peekTLV -> %d\n", PeekFP());

        auto PrintSym =
            must("lookup(printTLV)", JIT->lookup("printTLV"));
        auto PrintFP = PrintSym.toPtr<void(*)()>();
        fflush(stdout);
        PrintFP();
        fflush(stdout);
    }

    // ----------- load Swift "TLV" (actually swift_once) ---------
    //
    // tlv_v1.o has a Swift module-level `let computedAtFirstRead`
    // initialized by a closure. As documented at the top of the
    // file, this is NOT a Mach-O TLV; Swift emits a global +
    // swift_once-protected initializer. Still worth exercising:
    // requires swift_once to resolve via the process-symbol
    // generator, and tests Swift's global-init lifecycle under
    // MachOPlatform-managed JIT-link.
    {
        fprintf(stdout, "[host] loading Swift global-init object from %s\n",
                SwiftTLVPath);
        auto Buf = loadObject(SwiftTLVPath);
        must("addObjectFile(tlv_v1)",
             JIT->addObjectFile(MainJD, std::move(Buf)));

        auto Sym =
            must("lookup(readComputed)", JIT->lookup("readComputed"));
        auto FP = Sym.toPtr<void(*)()>();
        fprintf(stdout, "[host] readComputed -> %p; calling...\n",
                (void *)FP);
        fflush(stdout);
        FP();
        fflush(stdout);

        // Call again — should print same string (cached after first
        // swift_once init).
        fprintf(stdout, "[host] readComputed again (caching check)...\n");
        fflush(stdout);
        FP();
        fflush(stdout);
    }

    fprintf(stdout, "[host] done.\n");
    return 0;
}

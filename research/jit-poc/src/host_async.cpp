//===-- host_async.cpp - W2 JITLink POC Phase-2 step-3 host -----*- C++ -*-===//
//
// Phase-2 step-3 of the W2 JITLink POC. Validates that JITLink + an
// explicit `MachOPlatform` (backed by the ORC runtime) can ingest a
// Swift object file containing `async` functions and run them end-to-
// end through the Swift concurrency runtime.
//
// What this harness is checking, in priority order:
//   1. JITLink mechanics — does the object's async-specific section
//      layout link cleanly?  swiftc 6.x emits two extra sections
//      (`__TEXT,__swift_as_entry` + `__TEXT,__swift_as_ret`, both
//      `S_COALESCED`) with relocations. These appear to be the
//      successor sections to the older `__swift_async_extended_frame_info`
//      naming referenced in older docs.
//   2. Runtime symbol resolution — `_swift_task_create`,
//      `_swift_task_alloc`, `_swift_task_dealloc`, `_swift_task_switch`,
//      and Concurrency-stdlib refs (`Task.sleep` thunks, etc.) must
//      resolve.  These live in `libswift_Concurrency.dylib`; we must
//      `dlopen` it BEFORE JITLink hits the lookup (otherwise the
//      process-symbol generator won't see them).
//   3. Calling-convention correctness — the `@_cdecl("runAsync")`
//      wrapper spawns a Task, blocks on a semaphore, and reads the
//      result. If `swiftasynccc` lowering interacts badly with JITLink,
//      we'd see a hang (continuation never resumes) or a crash in the
//      async prologue.
//
// Setup mirrors host_objc.cpp:
//   * MachOPlatform via `ExecutorNativePlatform(OrcRTPath)`.
//   * Process-symbol generator on MainJD for Swift stdlib + libc.
//   * ObjCSelrefPlugin registered — Swift's concurrency machinery
//     touches ObjC selrefs (e.g. DispatchSemaphore is an ObjC class
//     via NSObject bridging), so we run with the same selref-uniquing
//     fix Phase-2 step-2.5 established.
//   * Eager dlopen of libswiftCore, Foundation, libswiftFoundation,
//     libswiftDispatch (for `DispatchSemaphore` thunks), and the
//     critical addition: `libswift_Concurrency.dylib`.
//
// Expected output on success (printed below by `runAsync` via Swift's
// `print`):
//
//     hello from async v1
//
// Failure modes the run log is the load-bearing record of:
//   * Link rejected (relocation kind unsupported) — JITLink error
//     message verbatim.
//   * `_swift_task_*` unresolved — which symbol, and where the
//     process-symbol search went.
//   * Hang — capture an SSH-into-self lldb stack if it happens (we
//     print pid before the call so the operator can attach).
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
#include <string>
#include <unistd.h>

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

int main(int argc, char **argv) {
    InitLLVM X(argc, argv);

    if (argc < 3 || argc > 4) {
        fprintf(stderr,
                "usage: %s <orc_rt_osx.a> <async_v1.o> [async_v2.o]\n",
                argv[0]);
        return 2;
    }
    const char *OrcRTPath = argv[1];
    const char *AsyncPath = argv[2];
    const char *AsyncPath2 = (argc == 4) ? argv[3] : nullptr;

    fprintf(stdout, "[host] pid=%d (attach with lldb if it hangs)\n",
            (int)getpid());

    InitializeNativeTarget();
    InitializeNativeTargetAsmPrinter();
    InitializeNativeTargetAsmParser();

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
    // The critical one for async: Concurrency runtime hosts
    // `swift_task_create`, `swift_task_alloc`, `swift_task_dealloc`,
    // `swift_task_switch`, and the Task/AsyncTask/Job/Executor types.
    tryDLOpen({"/usr/lib/swift/libswift_Concurrency.dylib",
               "@rpath/libswift_Concurrency.dylib",
               "libswift_Concurrency.dylib"},
              "libswift_Concurrency");
    tryDLOpen({"/System/Library/Frameworks/Foundation.framework/Foundation",
               "Foundation.framework/Foundation"},
              "Foundation.framework");
    tryDLOpen({"/usr/lib/swift/libswiftFoundation.dylib",
               "libswiftFoundation.dylib"},
              "libswiftFoundation");
    // DispatchSemaphore lives in libdispatch, but the Swift overlay
    // (signal/wait extensions on `DispatchSemaphore`) lives in
    // libswiftDispatch.
    tryDLOpen({"/usr/lib/swift/libswiftDispatch.dylib",
               "libswiftDispatch.dylib"},
              "libswiftDispatch");

    auto callAsync = [&](const char *Path, const char *Label) {
        fprintf(stdout, "[host] %s: loading async object from %s\n",
                Label, Path);
        auto Buf = loadObject(Path);
        std::string AddMsg = std::string("addObjectFile(") + Label + ")";
        must(AddMsg.c_str(),
             JIT->addObjectFile(MainJD, std::move(Buf)));

        auto Sym = must("lookup(runAsync)", JIT->lookup("runAsync"));
        auto FP = Sym.toPtr<void(*)()>();
        fprintf(stdout, "[host] %s: runAsync -> %p; calling...\n",
                Label, (void *)FP);
        fflush(stdout);
        FP();
        fflush(stdout);
        fprintf(stdout, "[host] %s: runAsync returned cleanly.\n",
                Label);
    };

    callAsync(AsyncPath, "v1");
    if (AsyncPath2)
        callAsync(AsyncPath2, "v2");

    fprintf(stdout, "[host] done.\n");
    return 0;
}

#include "llvm/ExecutionEngine/Orc/Shared/AllocationActions.h"
#include "llvm/ExecutionEngine/Orc/Shared/ExecutorAddress.h"
#include "llvm/ExecutionEngine/Orc/Shared/MemoryFlags.h"
#include "llvm/ExecutionEngine/Orc/Shared/TargetProcessControlTypes.h"
#include "llvm/ExecutionEngine/Orc/Shared/WrapperFunctionUtils.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/ExecutorSharedMemoryMapperService.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/JITLoaderGDB.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/RegisterEHFrames.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleExecutorDylibManager.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleExecutorMemoryManager.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleRemoteEPCServer.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/Memory.h"
#include "llvm/Support/raw_ostream.h"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <unistd.h>
#include <vector>

using namespace llvm;
using namespace llvm::orc;

// #391 diagnostic (count-only, behavior-neutral). The event_loop_probe fixture
// (JIT-loaded into this process) reads these back via dlsym, so the readers
// must survive dead-strip and stay in the executable's export table —
// LLVM_ATTRIBUTE_USED keeps them, matching linkComponents above. On a red:
// sessionNull==1/enteredNSAppRun==0 => the agent took the CFRunLoop fallback
// (CGSession was null); enteredNSAppRun==1 with loopIterations climbing => it
// entered [NSApp run] but the event was never delivered; loopIterations flat =>
// the loop is frozen. None of these dequeue or dispatch, so they cannot mask a
// wedge.
namespace {
std::atomic<int32_t> gLoopIterations{0};
std::atomic<int32_t> gSessionNull{0};
std::atomic<int32_t> gEnteredNSAppRun{0};
// #391 duration probe: ms to first non-null CGSession after a null-at-startup,
// measured on a side thread. -2 = probe didn't run, -1 = never recovered in the
// window, >=0 = ms to recovery. Decides transient (bounded retry fixes) vs
// persistent (retry futile).
std::atomic<int32_t> gRecoveryMs{-2};
} // namespace

LLVM_ATTRIBUTE_USED extern "C" int32_t previewAgentLoopIterations() {
  return gLoopIterations.load(std::memory_order_relaxed);
}
LLVM_ATTRIBUTE_USED extern "C" int32_t previewAgentSessionNull() {
  return gSessionNull.load(std::memory_order_relaxed);
}
LLVM_ATTRIBUTE_USED extern "C" int32_t previewAgentEnteredNSAppRun() {
  return gEnteredNSAppRun.load(std::memory_order_relaxed);
}
LLVM_ATTRIBUTE_USED extern "C" int32_t previewAgentRecoveryMs() {
  return gRecoveryMs.load(std::memory_order_relaxed);
}

LLVM_ATTRIBUTE_USED void linkComponents() {
  errs() << (void *)&llvm_orc_registerEHFrameSectionWrapper
         << (void *)&llvm_orc_deregisterEHFrameSectionWrapper
         << (void *)&llvm_orc_registerJITLoaderGDBWrapper
         << (void *)&llvm_orc_registerJITLoaderGDBAllocAction;
}

using namespace llvm::orc::shared;

namespace {

llvm::Error registerSwiftSection(const char *Symbol,
                                 llvm::orc::ExecutorAddrRange R) {
  using Fn = void (*)(const void *, const void *);
  auto *fn = reinterpret_cast<Fn>(dlsym(RTLD_DEFAULT, Symbol));
  if (!fn)
    return llvm::make_error<llvm::StringError>(
        std::string("PreviewAgent: Swift runtime symbol not found: ") + Symbol,
        llvm::inconvertibleErrorCode());
  fn(R.Start.toPtr<const void *>(), R.End.toPtr<const void *>());
  return llvm::Error::success();
}

CWrapperFunctionResult previewsmcp_register_conformances(const char *ArgData,
                                                         size_t ArgSize) {
  return WrapperFunction<SPSError(SPSExecutorAddrRange)>::handle(
             ArgData, ArgSize,
             [](llvm::orc::ExecutorAddrRange R) {
               return registerSwiftSection("swift_registerProtocolConformances",
                                           R);
             })
      .release();
}

CWrapperFunctionResult previewsmcp_register_types(const char *ArgData,
                                                  size_t ArgSize) {
  return WrapperFunction<SPSError(SPSExecutorAddrRange)>::handle(
             ArgData, ArgSize,
             [](llvm::orc::ExecutorAddrRange R) {
               return registerSwiftSection("swift_registerTypeMetadataRecords",
                                           R);
             })
      .release();
}

struct MainThreadCall {
  int32_t (*Fn)();
  int32_t Result;
};

void invokeOnMain(void *Ctx) {
  auto *Call = static_cast<MainThreadCall *>(Ctx);
  Call->Result = Call->Fn();
}

CWrapperFunctionResult previewsmcp_run_on_main(const char *ArgData,
                                               size_t ArgSize) {
  return WrapperFunction<int32_t(SPSExecutorAddr)>::handle(
             ArgData, ArgSize,
             [](llvm::orc::ExecutorAddr FnAddr) -> int32_t {
               MainThreadCall Call{FnAddr.toPtr<int32_t (*)()>(), 0};
               dispatch_sync_f(dispatch_get_main_queue(), &Call, invokeOnMain);
               return Call.Result;
             })
      .release();
}

struct AnonAllocation {
  size_t Size;
  std::vector<WrapperFunctionCall> DeallocActions;
};

std::mutex AnonMapperMutex;
std::map<void *, size_t> AnonReservations;
std::map<llvm::orc::ExecutorAddr, AnonAllocation> AnonAllocations;

CWrapperFunctionResult previewsmcp_anon_reserve(const char *ArgData,
                                                size_t ArgSize) {
  return WrapperFunction<SPSExpected<SPSExecutorAddr>(uint64_t)>::handle(
             ArgData, ArgSize,
             [](uint64_t Size) -> Expected<llvm::orc::ExecutorAddr> {
               std::error_code EC;
               auto MB = sys::Memory::allocateMappedMemory(
                   Size, nullptr, sys::Memory::MF_READ | sys::Memory::MF_WRITE,
                   EC);
               if (EC)
                 return errorCodeToError(EC);
               std::lock_guard<std::mutex> Lock(AnonMapperMutex);
               AnonReservations[MB.base()] = Size;
               return llvm::orc::ExecutorAddr::fromPtr(MB.base());
             })
      .release();
}

CWrapperFunctionResult previewsmcp_anon_initialize(const char *ArgData,
                                                   size_t ArgSize) {
  using namespace llvm::orc::tpctypes;
  return WrapperFunction<SPSExpected<SPSExecutorAddr>(SPSFinalizeRequest)>::
      handle(ArgData, ArgSize,
             [](FinalizeRequest FR) -> Expected<llvm::orc::ExecutorAddr> {
               llvm::orc::ExecutorAddr Base(~0ULL);
               llvm::orc::ExecutorAddr End(0);
               for (auto &Seg : FR.Segments) {
                 Base = std::min(Base, Seg.Addr);
                 End = std::max(End, Seg.Addr + Seg.Size);
               }
               for (auto &Seg : FR.Segments) {
                 char *Mem = Seg.Addr.toPtr<char *>();
                 if (!Seg.Content.empty())
                   memcpy(Mem, Seg.Content.data(), Seg.Content.size());
                 memset(Mem + Seg.Content.size(), 0,
                        Seg.Size - Seg.Content.size());
                 sys::MemoryBlock MB(Mem, Seg.Size);
                 if (auto EC = sys::Memory::protectMappedMemory(
                         MB, toSysMemoryProtectionFlags(Seg.RAG.Prot)))
                   return errorCodeToError(EC);
                 if ((Seg.RAG.Prot & MemProt::Exec) == MemProt::Exec)
                   sys::Memory::InvalidateInstructionCache(Mem, Seg.Size);
               }
               auto Dealloc = runFinalizeActions(FR.Actions);
               if (!Dealloc)
                 return Dealloc.takeError();
               std::lock_guard<std::mutex> Lock(AnonMapperMutex);
               AnonAllocations[Base] = {End - Base, std::move(*Dealloc)};
               return Base;
             })
          .release();
}

CWrapperFunctionResult previewsmcp_anon_deinitialize(const char *ArgData,
                                                     size_t ArgSize) {
  return WrapperFunction<SPSError(SPSSequence<SPSExecutorAddr>)>::handle(
             ArgData, ArgSize,
             [](std::vector<llvm::orc::ExecutorAddr> Bases) -> Error {
               Error Err = Error::success();
               std::lock_guard<std::mutex> Lock(AnonMapperMutex);
               for (auto B : llvm::reverse(Bases)) {
                 auto I = AnonAllocations.find(B);
                 if (I == AnonAllocations.end())
                   continue;
                 if (auto E = runDeallocActions(I->second.DeallocActions))
                   Err = joinErrors(std::move(Err), std::move(E));
                 sys::MemoryBlock MB(B.toPtr<void *>(), I->second.Size);
                 if (auto EC = sys::Memory::protectMappedMemory(
                         MB, sys::Memory::MF_READ | sys::Memory::MF_WRITE))
                   Err = joinErrors(std::move(Err), errorCodeToError(EC));
                 AnonAllocations.erase(I);
               }
               return Err;
             })
      .release();
}

CWrapperFunctionResult previewsmcp_anon_release(const char *ArgData,
                                                size_t ArgSize) {
  return WrapperFunction<SPSError(SPSSequence<SPSExecutorAddr>)>::handle(
             ArgData, ArgSize,
             [](std::vector<llvm::orc::ExecutorAddr> Bases) -> Error {
               Error Err = Error::success();
               std::lock_guard<std::mutex> Lock(AnonMapperMutex);
               for (auto B : Bases) {
                 auto I = AnonReservations.find(B.toPtr<void *>());
                 if (I == AnonReservations.end())
                   continue;
                 sys::MemoryBlock MB(I->first, I->second);
                 if (auto EC = sys::Memory::releaseMappedMemory(MB))
                   Err = joinErrors(std::move(Err), errorCodeToError(EC));
                 AnonReservations.erase(I);
               }
               return Err;
             })
      .release();
}

CWrapperFunctionResult previewsmcp_write_pointers(const char *ArgData,
                                                  size_t ArgSize) {
  using namespace llvm::orc::tpctypes;
  return WrapperFunction<void(SPSSequence<SPSMemoryAccessPointerWrite>)>::
      handle(ArgData, ArgSize,
             [](std::vector<PointerWrite> Ws) {
               for (auto &W : Ws)
                 *W.Addr.toPtr<void **>() = W.Value.toPtr<void *>();
             })
          .release();
}

// Count-only run-loop observer for #391 diagnosis. Fires each time -[NSApp
// run]'s loop is about to wait, so loopIterations tells a live-but-starved loop
// from a frozen one. It never touches the event queue, so it cannot mask the
// wedge.
void noteLoopIteration(void * /*observer*/, unsigned long /*activity*/,
                       void * /*info*/) {
  gLoopIterations.fetch_add(1, std::memory_order_relaxed);
}

// Install the observer on the current (main) run loop. Best-effort: if any
// symbol is missing the agent still runs, just without the loop counter.
void installLoopObserver() {
  auto *ObserverCreate =
      reinterpret_cast<void *(*)(void *, unsigned long, unsigned char, long,
                                 void (*)(void *, unsigned long, void *),
                                 void *)>(
          dlsym(RTLD_DEFAULT, "CFRunLoopObserverCreate"));
  auto *GetCurrentLoop =
      reinterpret_cast<void *(*)()>(dlsym(RTLD_DEFAULT, "CFRunLoopGetCurrent"));
  auto *AddObserver = reinterpret_cast<void (*)(void *, void *, const void *)>(
      dlsym(RTLD_DEFAULT, "CFRunLoopAddObserver"));
  auto *CommonModes = reinterpret_cast<const void *const *>(
      dlsym(RTLD_DEFAULT, "kCFRunLoopCommonModes"));
  if (!ObserverCreate || !GetCurrentLoop || !AddObserver || !CommonModes)
    return;

  const unsigned long kBeforeWaiting = 1UL << 5;
  if (void *Observer = ObserverCreate(nullptr, kBeforeWaiting, /*repeats=*/1, 0,
                                      noteLoopIteration, nullptr))
    AddObserver(GetCurrentLoop(), Observer, *CommonModes);
}

} // namespace

static void printErrorAndExit(Twine ErrMsg) {
  errs() << "PreviewAgent error: " << ErrMsg.str() << "\n\n"
         << "Usage:\n  PreviewAgent filedescs=<infd>,<outfd>\n";
  exit(1);
}

int main(int argc, char *argv[]) {
  dlopen("/usr/lib/swift/libswiftCore.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswift_Concurrency.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswiftFoundation.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/usr/lib/swift/libswiftDispatch.dylib", RTLD_NOW | RTLD_GLOBAL);
  dlopen("/System/Library/Frameworks/AppKit.framework/AppKit",
         RTLD_NOW | RTLD_GLOBAL);
  dlopen("/System/Library/Frameworks/SwiftUI.framework/SwiftUI",
         RTLD_NOW | RTLD_GLOBAL);

  if (argc != 2)
    printErrorAndExit("expected exactly one argument");

  StringRef SpecifierType, Specifier;
  std::tie(SpecifierType, Specifier) = StringRef(argv[1]).split('=');
  if (SpecifierType != "filedescs")
    printErrorAndExit("invalid specifier type \"" + SpecifierType + "\"");

  StringRef InFDStr, OutFDStr;
  std::tie(InFDStr, OutFDStr) = Specifier.split(',');
  int InFD = 0, OutFD = 0;
  if (InFDStr.getAsInteger(10, InFD))
    printErrorAndExit(InFDStr + " is not a valid file descriptor");
  if (OutFDStr.getAsInteger(10, OutFD))
    printErrorAndExit(OutFDStr + " is not a valid file descriptor");

  std::thread ServerThread([InFD, OutFD] {
    ExitOnError ExitOnErr;
    ExitOnErr.setBanner("PreviewAgent: ");
    auto Server = ExitOnErr(SimpleRemoteEPCServer::Create<
                            FDSimpleRemoteEPCTransport>(
        [](SimpleRemoteEPCServer::Setup &S) -> Error {
          S.setDispatcher(
              std::make_unique<SimpleRemoteEPCServer::ThreadDispatcher>());
          S.bootstrapSymbols() =
              SimpleRemoteEPCServer::defaultBootstrapSymbols();
          S.bootstrapSymbols()["__previewsmcp_register_conformances"] =
              llvm::orc::ExecutorAddr::fromPtr(
                  &previewsmcp_register_conformances);
          S.bootstrapSymbols()["__previewsmcp_register_types"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_register_types);
          S.bootstrapSymbols()["__previewsmcp_write_pointers"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_write_pointers);
          S.bootstrapSymbols()["__previewsmcp_run_on_main"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_run_on_main);
          S.bootstrapSymbols()["__previewsmcp_anon_reserve"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_anon_reserve);
          S.bootstrapSymbols()["__previewsmcp_anon_initialize"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_anon_initialize);
          S.bootstrapSymbols()["__previewsmcp_anon_deinitialize"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_anon_deinitialize);
          S.bootstrapSymbols()["__previewsmcp_anon_release"] =
              llvm::orc::ExecutorAddr::fromPtr(&previewsmcp_anon_release);
          S.services().push_back(
              std::make_unique<rt_bootstrap::SimpleExecutorDylibManager>());
          S.services().push_back(
              std::make_unique<rt_bootstrap::SimpleExecutorMemoryManager>());
          S.services().push_back(
              std::make_unique<
                  rt_bootstrap::ExecutorSharedMemoryMapperService>());
          return Error::success();
        },
        InFD, OutFD));
    ExitOnErr(Server->waitForDisconnect());
    std::_Exit(0);
  });
  ServerThread.detach();

  if (auto *Load = reinterpret_cast<bool (*)()>(
          dlsym(RTLD_DEFAULT, "NSApplicationLoad")))
    Load();

  // Run the full AppKit event loop, not a bare CFRunLoop spin: windows hosted
  // in this process only receive window-server events (clicks, scrolls) when
  // -[NSApplication run] dequeues and dispatches them. The main dispatch
  // queue (run_on_main's dispatch_sync target) drains under it as well.
  // Guarded on an Aqua session being reachable: registering with the window
  // server from an SSH login or launchd context can kill the process, and
  // off-screen rendering works under the bare spin there.
  auto *SessionDict = reinterpret_cast<void *(*)()>(
      dlsym(RTLD_DEFAULT, "CGSessionCopyCurrentDictionary"));
  void *Session = SessionDict ? SessionDict() : nullptr;
  if (Session) {
    auto *GetClass = reinterpret_cast<void *(*)(const char *)>(
        dlsym(RTLD_DEFAULT, "objc_getClass"));
    auto *RegisterSel = reinterpret_cast<void *(*)(const char *)>(
        dlsym(RTLD_DEFAULT, "sel_registerName"));
    auto *MsgSend = reinterpret_cast<void *(*)(void *, void *)>(
        dlsym(RTLD_DEFAULT, "objc_msgSend"));
    if (GetClass && RegisterSel && MsgSend) {
      if (void *AppClass = GetClass("NSApplication")) {
        void *App = MsgSend(AppClass, RegisterSel("sharedApplication"));
        if (App) {
          installLoopObserver();
          gEnteredNSAppRun.store(1, std::memory_order_relaxed);
          MsgSend(App, RegisterSel("run")); // never returns
        }
      }
    }
  } else if (SessionDict) {
    gSessionNull.store(1, std::memory_order_relaxed);
    // #391 duration probe (measurement only). On a side thread so the main
    // thread still falls through to the fallback loop and keeps draining the
    // dispatch queue (runOnMain stays alive); this run still reds. Poll whether
    // and how fast CGSession recovers, to size a bounded retry (transient) or
    // rule it out (persistent).
    std::thread([SessionDict] {
      // 9s window: must finish (and store) before the test's ~10s poll budget
      // reads the counter and tears the agent down. A recovery later than that
      // is unusable by a bounded retry anyway, so it reads as never (-1).
      const int MaxMs = 9000, StepMs = 100;
      int Elapsed = 0;
      void *Recovered = nullptr;
      for (; Elapsed < MaxMs && !Recovered; Elapsed += StepMs) {
        usleep(StepMs * 1000);
        Recovered = SessionDict();
      }
      int32_t Result = Recovered ? Elapsed : -1;
      gRecoveryMs.store(Result, std::memory_order_relaxed);
      errs() << "PreviewAgent: CGSession recovery probe = " << Result << "ms\n";
    }).detach();
  }

  // Fallback when AppKit or the window server is unavailable: keep servicing
  // the main queue.
  auto *RunInMode =
      reinterpret_cast<int (*)(const void *, double, unsigned char)>(
          dlsym(RTLD_DEFAULT, "CFRunLoopRunInMode"));
  auto *DefaultMode = reinterpret_cast<const void *const *>(
      dlsym(RTLD_DEFAULT, "kCFRunLoopDefaultMode"));
  if (!RunInMode || !DefaultMode)
    printErrorAndExit("CoreFoundation run loop symbols not found");
  while (true)
    RunInMode(*DefaultMode, 0.25, false);
}

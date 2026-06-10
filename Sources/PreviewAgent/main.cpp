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

#include <cstdlib>
#include <cstring>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <map>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

using namespace llvm;
using namespace llvm::orc;

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

std::mutex AnonMapperMutex;
std::map<void *, size_t> AnonReservations;

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
               for (auto &Seg : FR.Segments)
                 Base = std::min(Base, Seg.Addr);
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
               return Base;
             })
          .release();
}

CWrapperFunctionResult previewsmcp_anon_deinitialize(const char *ArgData,
                                                     size_t ArgSize) {
  return WrapperFunction<SPSError(SPSSequence<SPSExecutorAddr>)>::handle(
             ArgData, ArgSize,
             [](std::vector<llvm::orc::ExecutorAddr>) -> Error {
               return Error::success();
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
  auto *GetClass = reinterpret_cast<void *(*)(const char *)>(
      dlsym(RTLD_DEFAULT, "objc_getClass"));
  auto *RegisterSel = reinterpret_cast<void *(*)(const char *)>(
      dlsym(RTLD_DEFAULT, "sel_registerName"));
  auto *MsgSend = reinterpret_cast<void *(*)(void *, void *)>(
      dlsym(RTLD_DEFAULT, "objc_msgSend"));
  if (GetClass && RegisterSel && MsgSend) {
    if (void *AppClass = GetClass("NSApplication")) {
      void *App = MsgSend(AppClass, RegisterSel("sharedApplication"));
      if (App)
        MsgSend(App, RegisterSel("run")); // never returns
    }
  }

  // Fallback when AppKit is unavailable: keep servicing the main queue.
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

#include "llvm/ExecutionEngine/Orc/Shared/ExecutorAddress.h"
#include "llvm/ExecutionEngine/Orc/Shared/TargetProcessControlTypes.h"
#include "llvm/ExecutionEngine/Orc/Shared/WrapperFunctionUtils.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/ExecutorSharedMemoryMapperService.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/JITLoaderGDB.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/RegisterEHFrames.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleExecutorDylibManager.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleExecutorMemoryManager.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleRemoteEPCServer.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <atomic>
#include <cstdlib>
#include <dispatch/dispatch.h>
#include <dlfcn.h>
#include <string>
#include <thread>

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

  std::atomic<bool> Done{false};
  std::thread ServerThread([InFD, OutFD, &Done] {
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
    Done.store(true);
    if (auto *GetMain = reinterpret_cast<void *(*)()>(
            dlsym(RTLD_DEFAULT, "CFRunLoopGetMain")))
      if (auto *Stop = reinterpret_cast<void (*)(void *)>(
              dlsym(RTLD_DEFAULT, "CFRunLoopStop")))
        Stop(GetMain());
  });

  if (auto *Load = reinterpret_cast<bool (*)()>(
          dlsym(RTLD_DEFAULT, "NSApplicationLoad")))
    Load();

  auto *RunInMode =
      reinterpret_cast<int (*)(const void *, double, unsigned char)>(
          dlsym(RTLD_DEFAULT, "CFRunLoopRunInMode"));
  auto *DefaultMode = reinterpret_cast<const void *const *>(
      dlsym(RTLD_DEFAULT, "kCFRunLoopDefaultMode"));
  if (!RunInMode || !DefaultMode)
    printErrorAndExit("CoreFoundation run loop symbols not found");
  while (!Done.load())
    RunInMode(*DefaultMode, 0.25, false);

  ServerThread.join();
  return 0;
}

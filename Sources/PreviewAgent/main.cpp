#include "llvm/ExecutionEngine/Orc/TargetProcess/ExecutorSharedMemoryMapperService.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/JITLoaderGDB.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/RegisterEHFrames.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleExecutorMemoryManager.h"
#include "llvm/ExecutionEngine/Orc/TargetProcess/SimpleRemoteEPCServer.h"
#include "llvm/Support/Error.h"
#include "llvm/Support/raw_ostream.h"

#include <cstdlib>
#include <string>

using namespace llvm;
using namespace llvm::orc;

LLVM_ATTRIBUTE_USED void linkComponents() {
  errs() << (void *)&llvm_orc_registerEHFrameSectionWrapper
         << (void *)&llvm_orc_deregisterEHFrameSectionWrapper
         << (void *)&llvm_orc_registerJITLoaderGDBWrapper
         << (void *)&llvm_orc_registerJITLoaderGDBAllocAction;
}

static void printErrorAndExit(Twine ErrMsg) {
  errs() << "PreviewAgent error: " << ErrMsg.str() << "\n\n"
         << "Usage:\n  PreviewAgent filedescs=<infd>,<outfd>\n";
  exit(1);
}

int main(int argc, char *argv[]) {
  ExitOnError ExitOnErr;
  ExitOnErr.setBanner(std::string(argv[0]) + ": ");

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

  auto Server =
      ExitOnErr(SimpleRemoteEPCServer::Create<FDSimpleRemoteEPCTransport>(
          [](SimpleRemoteEPCServer::Setup &S) -> Error {
            S.setDispatcher(
                std::make_unique<SimpleRemoteEPCServer::ThreadDispatcher>());
            S.bootstrapSymbols() =
                SimpleRemoteEPCServer::defaultBootstrapSymbols();
            S.services().push_back(
                std::make_unique<rt_bootstrap::SimpleExecutorMemoryManager>());
            S.services().push_back(
                std::make_unique<
                    rt_bootstrap::ExecutorSharedMemoryMapperService>());
            return Error::success();
          },
          InFD, OutFD));

  ExitOnErr(Server->waitForDisconnect());
  return 0;
}

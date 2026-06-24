#include "SwiftEntrySectionPlugin.hpp"

#include "llvm/ADT/SmallVector.h"
#include "llvm/ExecutionEngine/Orc/Shared/AllocationActions.h"
#include "llvm/ExecutionEngine/Orc/Shared/ExecutorAddress.h"
#include "llvm/ExecutionEngine/Orc/Shared/WrapperFunctionUtils.h"
#include "llvm/Support/Error.h"

using namespace llvm;
using namespace llvm::jitlink;
using namespace llvm::orc;
using namespace llvm::orc::shared;

extern "C" void swift_registerProtocolConformances(const void *begin,
                                                   const void *end);
extern "C" void swift_registerTypeMetadataRecords(const void *begin,
                                                  const void *end);

namespace previewsmcp {
namespace {

constexpr StringRef Swift5ProtoSection = "__TEXT,__swift5_proto";
constexpr StringRef Swift5TypesSection = "__TEXT,__swift5_types";
constexpr StringRef HiddenProtoSection = "__DATA,__pvz_s5proto";
constexpr StringRef HiddenTypesSection = "__DATA,__pvz_s5types";

CWrapperFunctionResult registerConformances(const char *ArgData,
                                            size_t ArgSize) {
  return WrapperFunction<SPSError(SPSExecutorAddrRange)>::handle(
             ArgData, ArgSize,
             [](ExecutorAddrRange R) -> Error {
               swift_registerProtocolConformances(R.Start.toPtr<const void *>(),
                                                  R.End.toPtr<const void *>());
               return Error::success();
             })
      .release();
}

CWrapperFunctionResult registerTypes(const char *ArgData, size_t ArgSize) {
  return WrapperFunction<SPSError(SPSExecutorAddrRange)>::handle(
             ArgData, ArgSize,
             [](ExecutorAddrRange R) -> Error {
               swift_registerTypeMetadataRecords(R.Start.toPtr<const void *>(),
                                                 R.End.toPtr<const void *>());
               return Error::success();
             })
      .release();
}

void hideSection(LinkGraph &G, StringRef From, StringRef To) {
  auto *Src = G.findSectionByName(From);
  if (!Src)
    return;
  auto &Dst = G.createSection(To, Src->getMemProt());
  G.mergeSections(Dst, *Src);
  SmallVector<Block *> Blocks(Dst.blocks().begin(), Dst.blocks().end());
  for (auto *B : Blocks)
    G.addAnonymousSymbol(*B, 0, B->getSize(), false, true);
}

void registerSection(LinkGraph &G, StringRef Name, ExecutorAddr Fn) {
  auto *Sec = G.findSectionByName(Name);
  if (!Sec)
    return;
  for (auto *B : Sec->blocks()) {
    if (B->getSize() == 0)
      continue;
    ExecutorAddrRange range(B->getAddress(), B->getAddress() + B->getSize());
    G.allocActions().push_back(
        {cantFail(WrapperFunctionCall::Create<SPSArgList<SPSExecutorAddrRange>>(
             Fn, range)),
         {}});
  }
}

} // namespace

std::shared_ptr<SwiftEntrySectionPlugin> SwiftEntrySectionPlugin::inProcess() {
  return std::make_shared<SwiftEntrySectionPlugin>(
      ExecutorAddr::fromPtr(&registerConformances),
      ExecutorAddr::fromPtr(&registerTypes));
}

void SwiftEntrySectionPlugin::modifyPassConfig(
    MaterializationResponsibility &MR, LinkGraph &G,
    PassConfiguration &Config) {
  Config.PrePrunePasses.push_back([](LinkGraph &G) -> Error {
    hideSection(G, Swift5ProtoSection, HiddenProtoSection);
    hideSection(G, Swift5TypesSection, HiddenTypesSection);
    return Error::success();
  });
  Config.PostFixupPasses.push_back(
      [Conformances = RegisterConformances,
       Types = RegisterTypes](LinkGraph &G) -> Error {
        registerSection(G, HiddenProtoSection, Conformances);
        registerSection(G, HiddenTypesSection, Types);
        return Error::success();
      });
}

} // namespace previewsmcp

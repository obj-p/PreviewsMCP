#pragma once

#include "llvm/ExecutionEngine/JITLink/JITLink.h"
#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/ExecutionEngine/Orc/Shared/ExecutorAddress.h"
#include "llvm/Support/Error.h"

#include <memory>

namespace previewsmcp {

class SwiftEntrySectionPlugin : public llvm::orc::ObjectLinkingLayer::Plugin {
public:
  SwiftEntrySectionPlugin(llvm::orc::ExecutorAddr RegisterConformances,
                          llvm::orc::ExecutorAddr RegisterTypes)
      : RegisterConformances(RegisterConformances),
        RegisterTypes(RegisterTypes) {}

  static std::shared_ptr<SwiftEntrySectionPlugin> inProcess();

  void modifyPassConfig(llvm::orc::MaterializationResponsibility &MR,
                        llvm::jitlink::LinkGraph &G,
                        llvm::jitlink::PassConfiguration &Config) override;

  llvm::Error
  notifyFailed(llvm::orc::MaterializationResponsibility &MR) override {
    return llvm::Error::success();
  }
  llvm::Error notifyRemovingResources(llvm::orc::JITDylib &JD,
                                      llvm::orc::ResourceKey K) override {
    return llvm::Error::success();
  }
  void notifyTransferringResources(llvm::orc::JITDylib &JD,
                                   llvm::orc::ResourceKey DstKey,
                                   llvm::orc::ResourceKey SrcKey) override {}

private:
  llvm::orc::ExecutorAddr RegisterConformances;
  llvm::orc::ExecutorAddr RegisterTypes;
};

} // namespace previewsmcp

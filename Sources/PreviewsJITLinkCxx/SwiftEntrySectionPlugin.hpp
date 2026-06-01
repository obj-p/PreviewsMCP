#pragma once

#include "llvm/ExecutionEngine/JITLink/JITLink.h"
#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/Support/Error.h"

namespace previewsmcp {

class SwiftEntrySectionPlugin
    : public llvm::orc::ObjectLinkingLayer::Plugin {
public:
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
};

} // namespace previewsmcp

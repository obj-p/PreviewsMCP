//===-- ObjCSelrefPlugin.hpp - JITLink ObjC selref uniquing plugin -*- C++ -*-===//
//
// W2 JITLink POC, Phase-2 step-2.5.
//
// Public LLVM's `MachOPlatform` processes `__objc_imageinfo` for the
// link-graph, but does NOT register the selector strings in
// `__objc_selrefs` with the ObjC runtime. After JITLink finishes, each
// selref slot holds a pointer into the JIT image's own `__objc_methname`
// C-strings. `objc_msgSend` looks up its first argument in the global
// SEL hashtable (`sel_registerName` interns there) — when the selref
// is a JIT cstring instead, msgSend doesn't recognize it, falls into
// `__forwarding__`, and the process aborts.
//
// This plugin closes the gap by replacing every selref edge in the
// LinkGraph with an Absolute symbol target whose address is
// `sel_registerName(cstr)`. After the rewrite, fixup writes the
// canonical SEL into each selref slot, and `objc_msgSend` sees the
// same pointers it would from a normally-linked image.
//
// Apple's `XOJITExecutor` has to do equivalent work — see
// `research/scripts/analysis/q6-jit-runtime-findings.md` — they just
// hide it behind a statically-linked LLVM build.
//
//===----------------------------------------------------------------------===//

#pragma once

#include "llvm/ExecutionEngine/JITLink/JITLink.h"
#include "llvm/ExecutionEngine/Orc/Core.h"
#include "llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h"
#include "llvm/Support/Error.h"

namespace previewsvm {

class ObjCSelrefPlugin
    : public llvm::orc::ObjectLinkingLayer::Plugin {
public:
    explicit ObjCSelrefPlugin(bool Verbose = false) : Verbose(Verbose) {}

    void modifyPassConfig(
        llvm::orc::MaterializationResponsibility &MR,
        llvm::jitlink::LinkGraph &G,
        llvm::jitlink::PassConfiguration &Config) override;

    // Required pure-virtual overrides. We don't manage any
    // cross-link state, so these are no-ops.
    llvm::Error notifyFailed(
        llvm::orc::MaterializationResponsibility &MR) override {
        return llvm::Error::success();
    }
    llvm::Error notifyRemovingResources(
        llvm::orc::JITDylib &JD,
        llvm::orc::ResourceKey K) override {
        return llvm::Error::success();
    }
    void notifyTransferringResources(
        llvm::orc::JITDylib &JD,
        llvm::orc::ResourceKey DstKey,
        llvm::orc::ResourceKey SrcKey) override {}

private:
    bool Verbose;
};

} // namespace previewsvm

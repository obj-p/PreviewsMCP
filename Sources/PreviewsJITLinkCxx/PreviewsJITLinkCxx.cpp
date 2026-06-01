#include "PreviewsJITLinkCxx.h"
#include "SwiftEntrySectionPlugin.hpp"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/ExecutionEngine/Orc/MapperJITLinkMemoryManager.h>
#include <llvm/ExecutionEngine/Orc/MemoryMapper.h>
#include <llvm/ExecutionEngine/Orc/ExecutorProcessControl.h>
#include <llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h>
#include <llvm/Support/Debug.h>
#include <llvm/Support/MemoryBuffer.h>
#include <mutex>
#include <string>

namespace {

// Path to the orc runtime archive, injected by Package.swift (built from the
// Swift LLVM fork via scripts/build-jit-llvm.sh). Scaffolding: when LLVM is
// bundled this should resolve from the bundle, ideally a Swift-resolved param.
#ifndef PREVIEWSMCP_ORC_RT_PATH
#define PREVIEWSMCP_ORC_RT_PATH                                                 \
  "/opt/homebrew/opt/llvm/lib/clang/22/lib/darwin/liborc_rt_osx.a"
#endif
const char *kOrcRuntimePath = PREVIEWSMCP_ORC_RT_PATH;

// One contiguous reservation so code, data, and synthesized unwind info land
// within 32-bit reach of each other. The default per-allocation mmap scatters
// them past 4GB under ASLR, which breaks __unwind_info's 32-bit deltas.
constexpr size_t kSlabSize = size_t(1) << 30;

llvm::Expected<std::unique_ptr<llvm::orc::ObjectLayer>>
slabLinkingLayer(llvm::orc::ExecutionSession &es, const llvm::Triple &) {
  auto memMgr = llvm::orc::MapperJITLinkMemoryManager::CreateWithMapper<
      llvm::orc::InProcessMemoryMapper>(kSlabSize);
  if (!memMgr) {
    return memMgr.takeError();
  }
  auto layer = std::make_unique<llvm::orc::ObjectLinkingLayer>(
      es, std::move(*memMgr));
  layer->addPlugin(std::make_shared<previewsmcp::SwiftEntrySectionPlugin>());
  return layer;
}

llvm::Expected<std::unique_ptr<llvm::orc::LLJIT>> makeJIT() {
  static std::once_flag once;
  std::call_once(once, [] {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
    if (getenv("PREVIEWSMCP_JIT_DEBUG")) {
      static const char *types[] = {"jitlink", "orc"};
      llvm::DebugFlag = true;
      llvm::setCurrentDebugTypes(types, 2);
    }
  });

  auto epc = llvm::orc::SelfExecutorProcessControl::Create();
  if (!epc) {
    return epc.takeError();
  }

  return llvm::orc::LLJITBuilder()
      .setExecutorProcessControl(std::move(*epc))
      .setPlatformSetUp(llvm::orc::ExecutorNativePlatform(kOrcRuntimePath))
      .setObjectLinkingLayerCreator(slabLinkingLayer)
      .create();
}

const char *toCStr(llvm::Error err) {
  if (!err) {
    return nullptr;
  }
  return strdup(llvm::toString(std::move(err)).c_str());
}

} // namespace

struct previewsmcp_jit_session {
  std::unique_ptr<llvm::orc::LLJIT> jit;
  bool initialized = false;
};

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

const char *previewsmcp_jit_session_create(previewsmcp_jit_session **out_session) {
  auto jit = makeJIT();
  if (!jit) {
    return strdup(llvm::toString(jit.takeError()).c_str());
  }
  *out_session = new previewsmcp_jit_session{std::move(*jit), false};
  return nullptr;
}

const char *previewsmcp_jit_session_add_object(previewsmcp_jit_session *session,
                                               const char *object_path) {
  auto buf = llvm::MemoryBuffer::getFile(object_path);
  if (!buf) {
    return toCStr(llvm::errorCodeToError(buf.getError()));
  }
  return toCStr(session->jit->addObjectFile(std::move(*buf)));
}

const char *previewsmcp_jit_session_lookup(previewsmcp_jit_session *session,
                                           const char *symbol_name,
                                           uint64_t *out_address) {
  if (!session->initialized) {
    if (auto err = session->jit->initialize(session->jit->getMainJITDylib())) {
      return toCStr(std::move(err));
    }
    session->initialized = true;
  }
  auto sym = session->jit->lookup(symbol_name);
  if (!sym) {
    return toCStr(sym.takeError());
  }
  *out_address = sym->getValue();
  return nullptr;
}

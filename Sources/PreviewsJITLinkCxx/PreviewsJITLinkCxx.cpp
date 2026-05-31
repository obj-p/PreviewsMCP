#include "PreviewsJITLinkCxx.h"

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
  return std::make_unique<llvm::orc::ObjectLinkingLayer>(es,
                                                         std::move(*memMgr));
}

llvm::Expected<std::unique_ptr<llvm::orc::LLJIT>> makeJIT() {
  static std::once_flag once;
  std::call_once(once, [] {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
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

llvm::Expected<std::string> mainDylibName() {
  auto jit = makeJIT();
  if (!jit) {
    return jit.takeError();
  }
  return (*jit)->getMainJITDylib().getName();
}

llvm::Expected<uint64_t> linkAndCall(const char *const *object_paths,
                                     size_t object_count,
                                     const char *symbol_name) {
  auto jit = makeJIT();
  if (!jit) {
    return jit.takeError();
  }

  for (size_t i = 0; i < object_count; ++i) {
    auto buf = llvm::MemoryBuffer::getFile(object_paths[i]);
    if (!buf) {
      return llvm::errorCodeToError(buf.getError());
    }
    if (auto err = (*jit)->addObjectFile(std::move(*buf))) {
      return std::move(err);
    }
  }

  if (auto err = (*jit)->initialize((*jit)->getMainJITDylib())) {
    return std::move(err);
  }

  auto sym = (*jit)->lookup(symbol_name);
  if (!sym) {
    return sym.takeError();
  }
  return sym->toPtr<uint64_t (*)()>()();
}

template <typename T, typename Writer>
const char *marshal(llvm::Expected<T> result, Writer write) {
  if (!result) {
    return strdup(llvm::toString(result.takeError()).c_str());
  }
  write(std::move(*result));
  return nullptr;
}

} // namespace

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

const char *previewsmcp_jit_link_and_call(const char *const *object_paths,
                                          size_t object_count,
                                          const char *symbol_name,
                                          uint64_t *out_value) {
  return marshal(linkAndCall(object_paths, object_count, symbol_name),
                 [&](uint64_t value) { *out_value = value; });
}

const char *previewsmcp_jit_main_dylib_name(char **out_name) {
  return marshal(mainDylibName(),
                 [&](std::string name) { *out_name = strdup(name.c_str()); });
}

const char *previewsmcp_jit_target_triple(void) {
  char *targetTriple = LLVMGetDefaultTargetTriple();
  char *copy = strdup(targetTriple);
  LLVMDisposeMessage(targetTriple);
  return copy;
}

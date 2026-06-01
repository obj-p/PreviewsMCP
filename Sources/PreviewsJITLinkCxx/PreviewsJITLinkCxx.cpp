#include "PreviewsJITLinkCxx.h"
#include "SwiftEntrySectionPlugin.hpp"

#include <atomic>
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

llvm::Expected<std::unique_ptr<llvm::orc::LLJIT>>
makeJIT(const char *orc_rt_path) {
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
      .setPlatformSetUp(llvm::orc::ExecutorNativePlatform(orc_rt_path))
      .setObjectLinkingLayerCreator(slabLinkingLayer)
      .create();
}

const char *toCStr(llvm::Error err) {
  if (!err) {
    return nullptr;
  }
  return strdup(llvm::toString(std::move(err)).c_str());
}

llvm::orc::LLJIT *sharedJIT(const char *orc_rt_path, std::string &err) {
  static std::unique_ptr<llvm::orc::LLJIT> jit;
  static std::string initError;
  static std::once_flag once;
  std::call_once(once, [&] {
    auto created = makeJIT(orc_rt_path);
    if (!created) {
      initError = llvm::toString(created.takeError());
      return;
    }
    jit = std::move(*created);
  });
  if (!jit) {
    err = initError;
    return nullptr;
  }
  return jit.get();
}

} // namespace

struct previewsmcp_jit_session {
  llvm::orc::LLJIT *jit;
  llvm::orc::JITDylib *jd;
  bool initialized = false;
};

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

const char *previewsmcp_jit_session_create(previewsmcp_jit_session **out_session,
                                           const char *orc_rt_path) {
  std::string err;
  auto *jit = sharedJIT(orc_rt_path, err);
  if (!jit) {
    return strdup(err.c_str());
  }
  static std::atomic<uint64_t> counter{0};
  auto jd = jit->createJITDylib("session." +
                                std::to_string(counter.fetch_add(1)));
  if (!jd) {
    return toCStr(jd.takeError());
  }
  *out_session = new previewsmcp_jit_session{jit, &*jd, false};
  return nullptr;
}

const char *previewsmcp_jit_session_add_object(previewsmcp_jit_session *session,
                                               const char *object_path) {
  auto buf = llvm::MemoryBuffer::getFile(object_path);
  if (!buf) {
    return toCStr(llvm::errorCodeToError(buf.getError()));
  }
  return toCStr(session->jit->addObjectFile(*session->jd, std::move(*buf)));
}

const char *previewsmcp_jit_session_lookup(previewsmcp_jit_session *session,
                                           const char *symbol_name,
                                           uint64_t *out_address) {
  if (!session->initialized) {
    if (auto err = session->jit->initialize(*session->jd)) {
      return toCStr(std::move(err));
    }
    session->initialized = true;
  }
  auto sym = session->jit->lookup(*session->jd, symbol_name);
  if (!sym) {
    return toCStr(sym.takeError());
  }
  *out_address = sym->getValue();
  return nullptr;
}

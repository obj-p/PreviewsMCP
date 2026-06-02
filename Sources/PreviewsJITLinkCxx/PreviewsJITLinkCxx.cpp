#include "PreviewsJITLinkCxx.h"
#include "SwiftEntrySectionPlugin.hpp"

#include <atomic>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>
#include <llvm/ExecutionEngine/Orc/ExecutorProcessControl.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/ExecutionEngine/Orc/MapperJITLinkMemoryManager.h>
#include <llvm/ExecutionEngine/Orc/MemoryMapper.h>
#include <llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h>
#include <llvm/ExecutionEngine/Orc/Shared/SimpleRemoteEPCUtils.h>
#include <llvm/ExecutionEngine/Orc/SimpleRemoteEPC.h>
#include <llvm/ExecutionEngine/Orc/TaskDispatch.h>
#include <llvm/Support/Debug.h>
#include <llvm/Support/MemoryBuffer.h>
#include <crt_externs.h>
#include <csignal>
#include <mutex>
#include <optional>
#include <spawn.h>
#include <string>
#include <sys/socket.h>
#include <sys/wait.h>
#include <unistd.h>

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
  layer->addPlugin(previewsmcp::SwiftEntrySectionPlugin::inProcess());
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
  std::unique_ptr<llvm::orc::LLJIT> ownedJit;
  llvm::orc::LLJIT *jit = nullptr;
  llvm::orc::JITDylib *jd = nullptr;
  pid_t agentPid = 0;
  bool initialized = false;
};

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

void previewsmcp_jit_session_destroy(previewsmcp_jit_session *session) {
  if (!session) {
    return;
  }
  session->ownedJit.reset();
  if (session->agentPid != 0) {
    kill(session->agentPid, SIGKILL);
    waitpid(session->agentPid, nullptr, 0);
  }
  delete session;
}

const char *previewsmcp_jit_session_create(previewsmcp_jit_session **out_session,
                                           const char *orc_rt_path) {
  std::string err;
  auto *jit = sharedJIT(orc_rt_path, err);
  if (!jit) {
    return strdup(err.c_str());
  }
  static std::atomic<uint64_t> counter{0};
  auto jd =
      jit->createJITDylib("session." + std::to_string(counter.fetch_add(1)));
  if (!jd) {
    return toCStr(jd.takeError());
  }
  auto *session = new previewsmcp_jit_session{};
  session->jit = jit;
  session->jd = &*jd;
  *out_session = session;
  return nullptr;
}

const char *
previewsmcp_jit_remote_session_create(previewsmcp_jit_session **out_session,
                                      const char *agent_path,
                                      const char *orc_rt_path) {
  static std::once_flag targetOnce;
  std::call_once(targetOnce, [] {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
  });

  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
    return strdup(("socketpair failed: " + std::string(strerror(errno))).c_str());
  }

  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_addclose(&actions, sv[0]);
  std::string fdArg =
      "filedescs=" + std::to_string(sv[1]) + "," + std::to_string(sv[1]);
  char *const argv[] = {const_cast<char *>(agent_path),
                        const_cast<char *>(fdArg.c_str()), nullptr};
  pid_t pid = 0;
  int rc =
      posix_spawn(&pid, agent_path, &actions, nullptr, argv, *_NSGetEnviron());
  posix_spawn_file_actions_destroy(&actions);
  close(sv[1]);
  if (rc != 0) {
    close(sv[0]);
    return strdup(("posix_spawn failed: " + std::string(strerror(rc))).c_str());
  }

  auto epc =
      llvm::orc::SimpleRemoteEPC::Create<llvm::orc::FDSimpleRemoteEPCTransport>(
          std::make_unique<llvm::orc::DynamicThreadPoolTaskDispatcher>(
              std::nullopt),
          llvm::orc::SimpleRemoteEPC::Setup(), sv[0], sv[0]);
  if (!epc) {
    return toCStr(epc.takeError());
  }

  llvm::orc::ExecutorAddr registerConformances, registerTypes;
  if (auto err = (*epc)->getBootstrapSymbols(
          {{registerConformances, "__previewsmcp_register_conformances"},
           {registerTypes, "__previewsmcp_register_types"}})) {
    return toCStr(std::move(err));
  }

  auto jit =
      llvm::orc::LLJITBuilder()
          .setExecutorProcessControl(std::move(*epc))
          .setPlatformSetUp(llvm::orc::ExecutorNativePlatform(orc_rt_path))
          .setObjectLinkingLayerCreator(
              [registerConformances, registerTypes](
                  llvm::orc::ExecutionSession &es, const llvm::Triple &)
                  -> llvm::Expected<std::unique_ptr<llvm::orc::ObjectLayer>> {
                auto layer = std::make_unique<llvm::orc::ObjectLinkingLayer>(es);
                layer->addPlugin(
                    std::make_shared<previewsmcp::SwiftEntrySectionPlugin>(
                        registerConformances, registerTypes));
                return layer;
              })
          .create();
  if (!jit) {
    return toCStr(jit.takeError());
  }

  auto *session = new previewsmcp_jit_session{};
  session->ownedJit = std::move(*jit);
  session->jit = session->ownedJit.get();
  session->agentPid = pid;
  static std::atomic<uint64_t> counter{0};
  auto jd = session->jit->createJITDylib("remote." +
                                         std::to_string(counter.fetch_add(1)));
  if (!jd) {
    delete session;
    return toCStr(jd.takeError());
  }
  session->jd = &*jd;
  *out_session = session;
  return nullptr;
}

const char *previewsmcp_jit_session_run_main(previewsmcp_jit_session *session,
                                             const char *symbol_name,
                                             int32_t *out_result) {
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
  auto result = session->jit->getExecutionSession()
                    .getExecutorProcessControl()
                    .runAsMain(*sym, {});
  if (!result) {
    return toCStr(result.takeError());
  }
  *out_result = *result;
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

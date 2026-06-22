#include "PreviewsJITLinkCxx.h"
#include "SwiftEntrySectionPlugin.hpp"

#include <atomic>
#include <crt_externs.h>
#include <csignal>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <fcntl.h>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>
#include <llvm/ExecutionEngine/Orc/EPCDynamicLibrarySearchGenerator.h>
#include <llvm/ExecutionEngine/Orc/EPCGenericMemoryAccess.h>
#include <llvm/ExecutionEngine/Orc/ExecutionUtils.h>
#include <llvm/ExecutionEngine/Orc/ExecutorProcessControl.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/ExecutionEngine/Orc/MapperJITLinkMemoryManager.h>
#include <llvm/ExecutionEngine/Orc/MemoryMapper.h>
#include <llvm/ExecutionEngine/Orc/ObjectLinkingLayer.h>
#include <llvm/ExecutionEngine/Orc/Shared/ExecutorAddress.h>
#include <llvm/ExecutionEngine/Orc/Shared/SimpleRemoteEPCUtils.h>
#include <llvm/ExecutionEngine/Orc/Shared/TargetProcessControlTypes.h>
#include <llvm/ExecutionEngine/Orc/Shared/WrapperFunctionUtils.h>
#include <llvm/ExecutionEngine/Orc/SimpleRemoteEPC.h>
#include <llvm/ExecutionEngine/Orc/TaskDispatch.h>
#include <llvm/Support/Debug.h>
#include <llvm/Support/MemoryBuffer.h>
#include <map>
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
  auto layer =
      std::make_unique<llvm::orc::ObjectLinkingLayer>(es, std::move(*memMgr));
  layer->addPlugin(previewsmcp::SwiftEntrySectionPlugin::inProcess());
  return layer;
}

void initNativeTargetOnce() {
  static std::once_flag once;
  std::call_once(once, [] {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
  });
}

struct AnonMapperSymbols {
  llvm::orc::ExecutorAddr Reserve;
  llvm::orc::ExecutorAddr Initialize;
  llvm::orc::ExecutorAddr Deinitialize;
  llvm::orc::ExecutorAddr Release;
};

class PreviewsAnonymousMapper : public llvm::orc::MemoryMapper {
public:
  PreviewsAnonymousMapper(llvm::orc::SimpleRemoteEPC &epc,
                          AnonMapperSymbols sas)
      : epc(epc), sas(sas) {}

  ~PreviewsAnonymousMapper() override {
    std::lock_guard<std::mutex> lock(mutex);
    for (auto &entry : reservations) {
      free(entry.second.workingBuf);
    }
  }

  unsigned int getPageSize() override { return epc.getPageSize(); }

  void reserve(size_t numBytes, OnReservedFunction onReserved) override {
    epc.callSPSWrapperAsync<llvm::orc::shared::SPSExpected<
        llvm::orc::shared::SPSExecutorAddr>(uint64_t)>(
        sas.Reserve,
        [this, numBytes, onReserved = std::move(onReserved)](
            llvm::Error serErr,
            llvm::Expected<llvm::orc::ExecutorAddr> result) mutable {
          if (serErr) {
            llvm::consumeError(result.takeError());
            return onReserved(std::move(serErr));
          }
          if (!result) {
            return onReserved(result.takeError());
          }
          auto base = *result;
          auto *buf = static_cast<char *>(malloc(numBytes));
          {
            std::lock_guard<std::mutex> lock(mutex);
            reservations[base] = {buf, numBytes};
          }
          onReserved(llvm::orc::ExecutorAddrRange(base, base + numBytes));
        },
        static_cast<uint64_t>(numBytes));
  }

  char *prepare(llvm::orc::ExecutorAddr addr, size_t contentSize) override {
    std::lock_guard<std::mutex> lock(mutex);
    auto r = reservations.upper_bound(addr);
    bool covered = r != reservations.begin();
    if (covered) {
      --r;
      covered = addr + contentSize <= r->first + r->second.size;
    }
    if (!covered) {
      fprintf(stderr,
              "PreviewsAnonymousMapper::prepare: no reservation covers "
              "[0x%llx, +%zu)\n",
              addr.getValue(), contentSize);
      return nullptr;
    }
    return r->second.workingBuf + (addr - r->first);
  }

  void initialize(AllocInfo &ai, OnInitializedFunction onInitialized) override {
    llvm::orc::tpctypes::FinalizeRequest fr;
    fr.Actions = std::move(ai.Actions);
    char *base;
    {
      std::lock_guard<std::mutex> lock(mutex);
      auto r = reservations.upper_bound(ai.MappingBase);
      if (r == reservations.begin()) {
        return onInitialized(llvm::createStringError(
            llvm::inconvertibleErrorCode(),
            "initialize: no reservation covers mapping base"));
      }
      --r;
      auto resEnd = r->first + r->second.size;
      for (auto &seg : ai.Segments) {
        if (ai.MappingBase + seg.Offset + seg.ContentSize + seg.ZeroFillSize >
            resEnd) {
          return onInitialized(llvm::createStringError(
              llvm::inconvertibleErrorCode(),
              "initialize: segment extends past reservation"));
        }
      }
      base = r->second.workingBuf + (ai.MappingBase - r->first);
    }
    fr.Segments.reserve(ai.Segments.size());
    for (auto &seg : ai.Segments) {
      char *segBuf = base + seg.Offset;
      memset(segBuf + seg.ContentSize, 0, seg.ZeroFillSize);
      llvm::orc::tpctypes::SegFinalizeRequest sr;
      sr.RAG = {seg.AG.getMemProt(),
                seg.AG.getMemLifetime() == llvm::orc::MemLifetime::Finalize};
      sr.Addr = ai.MappingBase + seg.Offset;
      sr.Size = seg.ContentSize + seg.ZeroFillSize;
      sr.Content = llvm::ArrayRef<char>(segBuf, seg.ContentSize);
      fr.Segments.push_back(sr);
    }
    epc.callSPSWrapperAsync<
        llvm::orc::shared::SPSExpected<llvm::orc::shared::SPSExecutorAddr>(
            llvm::orc::shared::SPSFinalizeRequest)>(
        sas.Initialize,
        [onInitialized = std::move(onInitialized)](
            llvm::Error serErr,
            llvm::Expected<llvm::orc::ExecutorAddr> result) mutable {
          if (serErr) {
            llvm::consumeError(result.takeError());
            return onInitialized(std::move(serErr));
          }
          onInitialized(std::move(result));
        },
        std::move(fr));
  }

  void deinitialize(llvm::ArrayRef<llvm::orc::ExecutorAddr> allocs,
                    OnDeinitializedFunction onDeinit) override {
    epc.callSPSWrapperAsync<llvm::orc::shared::SPSError(
        llvm::orc::shared::SPSSequence<llvm::orc::shared::SPSExecutorAddr>)>(
        sas.Deinitialize,
        [onDeinit = std::move(onDeinit)](llvm::Error serErr,
                                         llvm::Error result) mutable {
          if (serErr) {
            llvm::consumeError(std::move(result));
            return onDeinit(std::move(serErr));
          }
          onDeinit(std::move(result));
        },
        allocs);
  }

  void release(llvm::ArrayRef<llvm::orc::ExecutorAddr> bases,
               OnReleasedFunction onReleased) override {
    {
      std::lock_guard<std::mutex> lock(mutex);
      for (auto b : bases) {
        auto i = reservations.find(b);
        if (i != reservations.end()) {
          free(i->second.workingBuf);
          reservations.erase(i);
        }
      }
    }
    epc.callSPSWrapperAsync<llvm::orc::shared::SPSError(
        llvm::orc::shared::SPSSequence<llvm::orc::shared::SPSExecutorAddr>)>(
        sas.Release,
        [onReleased = std::move(onReleased)](llvm::Error serErr,
                                             llvm::Error result) mutable {
          if (serErr) {
            llvm::consumeError(std::move(result));
            return onReleased(std::move(serErr));
          }
          onReleased(std::move(result));
        },
        bases);
  }

private:
  struct Reservation {
    char *workingBuf;
    size_t size;
  };
  llvm::orc::SimpleRemoteEPC &epc;
  AnonMapperSymbols sas;
  std::mutex mutex;
  std::map<llvm::orc::ExecutorAddr, Reservation> reservations;
};

llvm::Expected<std::unique_ptr<llvm::orc::LLJIT>>
makeJIT(const char *orc_rt_path) {
  initNativeTargetOnce();
  static std::once_flag debugOnce;
  std::call_once(debugOnce, [] {
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

void killAgent(pid_t pid) {
  if (pid == 0) {
    return;
  }
  kill(pid, SIGKILL);
  waitpid(pid, nullptr, 0);
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
  llvm::orc::ExecutorAddr runOnMain;
  pid_t agentPid = 0;
  bool initialized = false;
};

namespace {
llvm::Expected<llvm::orc::ExecutorAddr>
lookupInitialized(previewsmcp_jit_session *session, const char *symbol_name) {
  {
    static std::mutex initMutex;
    std::lock_guard<std::mutex> lock(initMutex);
    // Re-check under the lock: the flag is read and written only here, so two
    // threads cannot both pass the check and double-initialize the JITDylib.
    if (!session->initialized) {
      if (auto err = session->jit->initialize(*session->jd)) {
        return std::move(err);
      }
      session->initialized = true;
    }
  }
  return session->jit->lookup(*session->jd, symbol_name);
}
} // namespace

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

void previewsmcp_jit_session_destroy(previewsmcp_jit_session *session) {
  if (!session) {
    return;
  }
  session->ownedJit.reset();
  killAgent(session->agentPid);
  delete session;
}

const char *
previewsmcp_jit_session_create(previewsmcp_jit_session **out_session,
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

static const char *
createRemoteSessionFromFDs(previewsmcp_jit_session **out_session, int inFd,
                           int outFd, const char *orc_rt_path, pid_t pid) {
  llvm::orc::SimpleRemoteEPC::Setup setup;
  setup.CreateMemoryAccess = [](llvm::orc::SimpleRemoteEPC &epc)
      -> llvm::Expected<
          std::unique_ptr<llvm::orc::ExecutorProcessControl::MemoryAccess>> {
    llvm::orc::ExecutorAddr writePointers;
    if (auto err = epc.getBootstrapSymbols(
            {{writePointers, "__previewsmcp_write_pointers"}})) {
      return std::move(err);
    }
    llvm::orc::EPCGenericMemoryAccess::FuncAddrs fas;
    fas.WritePointers = writePointers;
    return std::make_unique<llvm::orc::EPCGenericMemoryAccess>(epc, fas);
  };

  auto epc =
      llvm::orc::SimpleRemoteEPC::Create<llvm::orc::FDSimpleRemoteEPCTransport>(
          std::make_unique<llvm::orc::DynamicThreadPoolTaskDispatcher>(
              std::nullopt),
          std::move(setup), inFd, outFd);
  if (!epc) {
    killAgent(pid);
    return toCStr(epc.takeError());
  }

  llvm::orc::ExecutorAddr registerConformances, registerTypes, runOnMain;
  if (auto err = (*epc)->getBootstrapSymbols(
          {{registerConformances, "__previewsmcp_register_conformances"},
           {registerTypes, "__previewsmcp_register_types"},
           {runOnMain, "__previewsmcp_run_on_main"}})) {
    llvm::consumeError((*epc)->disconnect());
    killAgent(pid);
    return toCStr(std::move(err));
  }

  AnonMapperSymbols anonSyms;
  if (auto err = (*epc)->getBootstrapSymbols(
          {{anonSyms.Reserve, "__previewsmcp_anon_reserve"},
           {anonSyms.Initialize, "__previewsmcp_anon_initialize"},
           {anonSyms.Deinitialize, "__previewsmcp_anon_deinitialize"},
           {anonSyms.Release, "__previewsmcp_anon_release"}})) {
    llvm::consumeError((*epc)->disconnect());
    killAgent(pid);
    return toCStr(std::move(err));
  }

  auto jit =
      llvm::orc::LLJITBuilder()
          .setExecutorProcessControl(std::move(*epc))
          .setPlatformSetUp(llvm::orc::ExecutorNativePlatform(orc_rt_path))
          .setObjectLinkingLayerCreator(
              [registerConformances, registerTypes,
               anonSyms](llvm::orc::ExecutionSession &es, const llvm::Triple &)
                  -> llvm::Expected<std::unique_ptr<llvm::orc::ObjectLayer>> {
                auto &srepc = static_cast<llvm::orc::SimpleRemoteEPC &>(
                    es.getExecutorProcessControl());
                auto memMgr =
                    std::make_unique<llvm::orc::MapperJITLinkMemoryManager>(
                        kSlabSize, std::make_unique<PreviewsAnonymousMapper>(
                                       srepc, anonSyms));
                auto layer = std::make_unique<llvm::orc::ObjectLinkingLayer>(
                    es, std::move(memMgr));
                layer->addPlugin(
                    std::make_shared<previewsmcp::SwiftEntrySectionPlugin>(
                        registerConformances, registerTypes));
                return layer;
              })
          .create();
  if (!jit) {
    killAgent(pid);
    return toCStr(jit.takeError());
  }

  auto *session = new previewsmcp_jit_session{};
  session->ownedJit = std::move(*jit);
  session->jit = session->ownedJit.get();
  session->runOnMain = runOnMain;
  session->agentPid = pid;
  static std::atomic<uint64_t> counter{0};
  auto jd = session->jit->createJITDylib("remote." +
                                         std::to_string(counter.fetch_add(1)));
  if (!jd) {
    auto err = toCStr(jd.takeError());
    previewsmcp_jit_session_destroy(session);
    return err;
  }
  session->jd = &*jd;
  *out_session = session;
  return nullptr;
}

const char *
previewsmcp_jit_remote_session_create(previewsmcp_jit_session **out_session,
                                      const char *agent_path,
                                      const char *orc_rt_path) {
  initNativeTargetOnce();

  int sv[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, sv) != 0) {
    return strdup(
        ("socketpair failed: " + std::string(strerror(errno))).c_str());
  }
  fcntl(sv[0], F_SETFD, FD_CLOEXEC);
  fcntl(sv[1], F_SETFD, FD_CLOEXEC);

  int childFd = (sv[0] > sv[1] ? sv[0] : sv[1]) + 1;
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  posix_spawn_file_actions_adddup2(&actions, sv[1], childFd);
  std::string fdArg =
      "filedescs=" + std::to_string(childFd) + "," + std::to_string(childFd);
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

  return createRemoteSessionFromFDs(out_session, sv[0], sv[0], orc_rt_path, pid);
}

const char *previewsmcp_jit_remote_session_create_from_fd(
    previewsmcp_jit_session **out_session, int fd, const char *orc_rt_path) {
  initNativeTargetOnce();
  return createRemoteSessionFromFDs(out_session, fd, fd, orc_rt_path, 0);
}

const char *previewsmcp_jit_session_run_main(previewsmcp_jit_session *session,
                                             const char *symbol_name,
                                             int32_t *out_result) {
  auto sym = lookupInitialized(session, symbol_name);
  if (!sym) {
    return toCStr(sym.takeError());
  }
  auto result =
      session->jit->getExecutionSession().getExecutorProcessControl().runAsMain(
          *sym, {});
  if (!result) {
    return toCStr(result.takeError());
  }
  *out_result = *result;
  return nullptr;
}

const char *
previewsmcp_jit_session_run_on_main(previewsmcp_jit_session *session,
                                    const char *symbol_name,
                                    int32_t *out_result) {
  if (!session->runOnMain) {
    return strdup("run_on_main requires a remote session");
  }
  auto sym = lookupInitialized(session, symbol_name);
  if (!sym) {
    return toCStr(sym.takeError());
  }
  auto &epc = session->jit->getExecutionSession().getExecutorProcessControl();
  int32_t result = 0;
  if (auto err =
          epc.callSPSWrapper<int32_t(llvm::orc::shared::SPSExecutorAddr)>(
              session->runOnMain, result, *sym)) {
    return toCStr(std::move(err));
  }
  *out_result = result;
  return nullptr;
}

const char *
previewsmcp_jit_session_write_pointer(previewsmcp_jit_session *session,
                                      uint64_t address, uint64_t value) {
  llvm::orc::tpctypes::PointerWrite writes[] = {
      {llvm::orc::ExecutorAddr(address), llvm::orc::ExecutorAddr(value)}};
  auto err = session->jit->getExecutionSession()
                 .getExecutorProcessControl()
                 .getMemoryAccess()
                 .writePointers(writes);
  return toCStr(std::move(err));
}

const char *previewsmcp_jit_session_add_object(previewsmcp_jit_session *session,
                                               const char *object_path) {
  auto buf = llvm::MemoryBuffer::getFile(object_path);
  if (!buf) {
    return toCStr(llvm::errorCodeToError(buf.getError()));
  }
  return toCStr(session->jit->addObjectFile(*session->jd, std::move(*buf)));
}

const char *
previewsmcp_jit_session_add_archive(previewsmcp_jit_session *session,
                                    const char *archive_path) {
  auto generator = llvm::orc::StaticLibraryDefinitionGenerator::Load(
      session->jit->getObjLinkingLayer(), archive_path);
  if (!generator) {
    return toCStr(generator.takeError());
  }
  session->jd->addGenerator(std::move(*generator));
  return nullptr;
}

const char *previewsmcp_jit_session_add_dylib(previewsmcp_jit_session *session,
                                              const char *dylib_path) {
  auto generator = llvm::orc::EPCDynamicLibrarySearchGenerator::Load(
      session->jit->getExecutionSession(), dylib_path);
  if (!generator) {
    return toCStr(generator.takeError());
  }
  session->jd->addGenerator(std::move(*generator));
  return nullptr;
}

const char *
previewsmcp_jit_session_new_generation(previewsmcp_jit_session *session) {
  static std::atomic<uint64_t> counter{0};
  auto jd = session->jit->createJITDylib("generation." +
                                         std::to_string(counter.fetch_add(1)));
  if (!jd) {
    return toCStr(jd.takeError());
  }
  session->jd = &*jd;
  session->initialized = false;
  return nullptr;
}

const char *previewsmcp_jit_session_lookup(previewsmcp_jit_session *session,
                                           const char *symbol_name,
                                           uint64_t *out_address) {
  auto sym = lookupInitialized(session, symbol_name);
  if (!sym) {
    return toCStr(sym.takeError());
  }
  *out_address = sym->getValue();
  return nullptr;
}

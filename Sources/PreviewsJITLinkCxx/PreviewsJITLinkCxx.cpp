#include "PreviewsJITLinkCxx.h"

#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <llvm/Support/MemoryBuffer.h>
#include <mutex>
#include <string>

namespace {

llvm::Expected<std::unique_ptr<llvm::orc::LLJIT>> makeJIT() {
  static std::once_flag once;
  std::call_once(once, [] {
    LLVMInitializeNativeTarget();
    LLVMInitializeNativeAsmPrinter();
  });
  return llvm::orc::LLJITBuilder().create();
}

llvm::Expected<std::string> mainDylibName() {
  auto jit = makeJIT();
  if (!jit) {
    return jit.takeError();
  }
  return (*jit)->getMainJITDylib().getName();
}

llvm::Expected<uint64_t> linkAndCall(const char *object_path,
                                     const char *symbol_name) {
  auto jit = makeJIT();
  if (!jit) {
    return jit.takeError();
  }

  auto buf = llvm::MemoryBuffer::getFile(object_path);
  if (!buf) {
    return llvm::errorCodeToError(buf.getError());
  }

  if (auto err = (*jit)->addObjectFile(std::move(*buf))) {
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

const char *previewsmcp_jit_link_and_call(const char *object_path,
                                          const char *symbol_name,
                                          uint64_t *out_value) {
  return marshal(linkAndCall(object_path, symbol_name),
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

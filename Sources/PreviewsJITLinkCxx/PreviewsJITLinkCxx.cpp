#include "PreviewsJITLinkCxx.h"

#include <cstdlib>
#include <cstring>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>
#include <llvm/ExecutionEngine/Orc/LLJIT.h>
#include <string>

namespace {

previewsmcp_jit_string_result_t okResult(const std::string &value) {
  return {strdup(value.c_str()), nullptr};
}

previewsmcp_jit_string_result_t errResult(const std::string &msg) {
  return {nullptr, strdup(msg.c_str())};
}

} // namespace

previewsmcp_jit_string_result_t previewsmcp_jit_main_dylib_name(void) {
  LLVMInitializeNativeTarget();
  LLVMInitializeNativeAsmPrinter();

  auto jitOrErr = llvm::orc::LLJITBuilder().create();
  if (!jitOrErr) {
    return errResult(llvm::toString(jitOrErr.takeError()));
  }
  auto &jit = **jitOrErr;
  return okResult(jit.getMainJITDylib().getName());
}

const char *previewsmcp_jit_target_triple(void) {
  char *targetTriple = LLVMGetDefaultTargetTriple();
  char *copy = strdup(targetTriple);
  LLVMDisposeMessage(targetTriple);
  return copy;
}

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

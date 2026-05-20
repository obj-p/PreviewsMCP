#include "PreviewsJITLinkCxx.h"

#include <cstdlib>
#include <cstring>
#include <llvm-c/Core.h>
#include <llvm-c/TargetMachine.h>

const char *previewsmcp_jit_target_triple(void) {
  char *targetTriple = LLVMGetDefaultTargetTriple();
  char *copy = strdup(targetTriple);
  LLVMDisposeMessage(targetTriple);
  return copy;
}

void previewsmcp_jit_dispose_string(const char *str) {
  free(const_cast<char *>(str));
}

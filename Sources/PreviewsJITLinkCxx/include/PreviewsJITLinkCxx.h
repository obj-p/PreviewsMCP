#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

typedef struct {
  const char *_Nullable value;
  const char *_Nullable error;
} previewsmcp_jit_string_result_t;

previewsmcp_jit_string_result_t previewsmcp_jit_main_dylib_name(void);

const char *previewsmcp_jit_target_triple(void);

void previewsmcp_jit_dispose_string(const char *str);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

#pragma once

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

void previewsmcp_jit_dispose_string(const char *str);

const char *_Nullable
previewsmcp_jit_link_and_call(const char *object_path, const char *symbol_name,
                              uint64_t *out_value);

const char *_Nullable
previewsmcp_jit_main_dylib_name(char *_Nullable *out_name);

const char *previewsmcp_jit_target_triple(void);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

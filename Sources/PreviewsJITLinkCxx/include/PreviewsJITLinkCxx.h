#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

void previewsmcp_jit_dispose_string(const char *str);

const char *_Nullable
previewsmcp_jit_link_and_call(const char *_Nonnull const *_Nonnull object_paths,
                             size_t object_count, const char *symbol_name,
                             uint64_t *out_value);

const char *_Nullable
previewsmcp_jit_main_dylib_name(char *_Nullable *_Nonnull out_name);

const char *previewsmcp_jit_target_triple(void);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

#if __has_feature(nullability)
#pragma clang assume_nonnull begin
#endif

const char *previewsmcp_jit_target_triple(void);

void previewsmcp_jit_dispose_string(const char *str);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

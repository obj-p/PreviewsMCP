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

typedef struct previewsmcp_jit_session previewsmcp_jit_session;

const char *_Nullable previewsmcp_jit_session_create(
    previewsmcp_jit_session *_Nullable *_Nonnull out_session,
    const char *orc_rt_path);

const char *_Nullable
previewsmcp_jit_remote_session_create(previewsmcp_jit_session *_Nullable *_Nonnull out_session,
                                      const char *agent_path);

const char *_Nullable
previewsmcp_jit_session_run_main(previewsmcp_jit_session *session,
                                 const char *symbol_name, int32_t *out_result);

const char *_Nullable
previewsmcp_jit_session_add_object(previewsmcp_jit_session *session,
                                   const char *object_path);

const char *_Nullable previewsmcp_jit_session_lookup(
    previewsmcp_jit_session *session, const char *symbol_name,
    uint64_t *out_address);

#if __has_feature(nullability)
#pragma clang assume_nonnull end
#endif

#ifdef __cplusplus
}
#endif

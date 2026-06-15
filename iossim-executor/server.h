#pragma once

#ifdef __cplusplus
extern "C" {
#endif

// Runs an ORC SimpleRemoteEPCServer over the given file descriptors, blocking
// until the daemon disconnects. Used by both the standalone iossim-executor and
// the in-app iOS JIT host. The Swift runtime and an event loop (for
// run_on_main) must already be available in the host process. Returns 0 on a
// clean disconnect, nonzero on error.
int previewsmcp_ios_executor_start(int in_fd, int out_fd);

#ifdef __cplusplus
}
#endif

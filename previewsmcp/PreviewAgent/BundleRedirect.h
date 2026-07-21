#ifndef PREVIEWSMCP_BUNDLE_REDIRECT_H
#define PREVIEWSMCP_BUNDLE_REDIRECT_H

/// Installs the agent-process +[NSBundle bundleForClass:] hook on first call
/// and stores (or replaces) the target framework wrapper path the hook
/// redirects to. Passing NULL clears the path, disabling redirection while
/// leaving the hook installed. See docs/jit-bundle-resolution.md.
void previewsmcp_set_resource_wrapper(const char *path);

#endif

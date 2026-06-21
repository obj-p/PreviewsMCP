"""Pin a target to the iOS-simulator platform via an outgoing transition.

The iossim LLVM cross-build must always build for the simulator regardless of
the top-level platform. This wraps a target and forces --platforms to the
ios-sim platform, so apple_support's toolchain supplies the simulator sysroot.
"""

def _ios_sim_transition_impl(_settings, _attr):
    return {"//command_line_option:platforms": "//bazel:ios_sim_arm64"}

_ios_sim_transition = transition(
    implementation = _ios_sim_transition_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _ios_sim_build_impl(ctx):
    return [DefaultInfo(files = depset(transitive = [t[DefaultInfo].files for t in ctx.attr.target]))]

ios_sim_build = rule(
    implementation = _ios_sim_build_impl,
    attrs = {
        "target": attr.label(cfg = _ios_sim_transition, mandatory = True),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
)

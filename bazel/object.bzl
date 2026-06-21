"""Compile a single C++ source to one object file for the iOS simulator.

The rule itself transitions to the iOS-simulator platform so apple_support's
toolchain supplies the simulator target + sysroot. Its `llvm_headers` dep is
pinned back to the host platform via an attribute transition, so the macOS
`//:llvm` cmake build is reused for its headers and is never rebuilt for iOS.
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _to_ios_sim_impl(_settings, _attr):
    return {"//command_line_option:platforms": "//bazel:ios_sim_arm64"}

_to_ios_sim = transition(
    implementation = _to_ios_sim_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _to_host_impl(_settings, _attr):
    return {"//command_line_option:platforms": "@bazel_tools//tools:host_platform"}

_to_host = transition(
    implementation = _to_host_impl,
    inputs = [],
    outputs = ["//command_line_option:platforms"],
)

def _cc_object_impl(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    feature_configuration = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    compilation_contexts = [
        dep[CcInfo].compilation_context
        for dep in ctx.attr.llvm_headers
    ]
    _, compilation_outputs = cc_common.compile(
        name = ctx.label.name,
        actions = ctx.actions,
        feature_configuration = feature_configuration,
        cc_toolchain = cc_toolchain,
        srcs = ctx.files.srcs,
        private_hdrs = ctx.files.hdrs,
        user_compile_flags = ctx.attr.copts,
        compilation_contexts = compilation_contexts,
    )
    objects = compilation_outputs.objects
    if len(objects) != 1:
        fail("cc_object expects exactly one object, got %d" % len(objects))
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.symlink(output = out, target_file = objects[0])
    return [DefaultInfo(files = depset([out]))]

cc_object = rule(
    implementation = _cc_object_impl,
    cfg = _to_ios_sim,
    attrs = {
        "srcs": attr.label_list(allow_files = [".cpp", ".cc"], mandatory = True),
        "hdrs": attr.label_list(allow_files = [".h", ".hpp"]),
        "copts": attr.string_list(),
        "out": attr.string(mandatory = True),
        "llvm_headers": attr.label_list(cfg = _to_host, providers = [CcInfo]),
        "_allowlist_function_transition": attr.label(
            default = "@bazel_tools//tools/allowlists/function_transition_allowlist",
        ),
    },
    toolchains = ["@bazel_tools//tools/cpp:toolchain_type"],
    fragments = ["cpp"],
)

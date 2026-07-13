"""Hermetic fetch of the swiftlang/llvm-project fork PreviewsJITLink links against.

Downloads a pinned, sha256-verified sparse source archive (the same tree the
former git sparse-checkout produced), applies the local patches with the
native `ctx.patch` (no git on PATH), strips a cyclic test symlink that
otherwise breaks Bazel's source glob, and writes the BUILD that consumes
@llvm_src//:all.

The archive is a self-hosted, immutable release asset. A `download_and_extract`
fetch is content-addressable, so it populates Bazel's repository cache and is
fetched once per machine — unlike the former `ctx.execute(git)` clone, which
bypassed the repository cache and re-ran per output base (a ~600s fetch each
time). The sha256 pin subsumes the old commit check.
"""

_BUILD_FILE = """\
filegroup(
    name = "all",
    srcs = glob(["**"], exclude = ["**/.git/**"]),
    visibility = ["//visibility:public"],
)
"""

def _llvm_repository_impl(ctx):
    ctx.download_and_extract(
        url = ctx.attr.url,
        sha256 = ctx.attr.sha256,
    )

    for patch in ctx.attr.patches:
        ctx.patch(ctx.path(patch), strip = 1)

    ctx.delete("llvm/test/tools/llvm-cas/Inputs/self")
    ctx.file("BUILD.bazel", _BUILD_FILE, executable = False)

llvm_repository = repository_rule(
    implementation = _llvm_repository_impl,
    attrs = {
        "url": attr.string(mandatory = True),
        "sha256": attr.string(mandatory = True),
        "patches": attr.label_list(allow_files = [".patch"]),
    },
)

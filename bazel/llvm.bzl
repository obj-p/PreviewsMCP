"""Hermetic fetch of the swiftlang/llvm-project fork PreviewsJITLink links against.

Clones the fork (shallow + sparse + partial, pinned to the exact commit),
applies the local patches, and strips a cyclic test
symlink that otherwise breaks Bazel's source glob. The cmake build of the result
lives in the BUILD file that consumes @llvm_src//:all.
"""

_BUILD_FILE = """\
filegroup(
    name = "all",
    srcs = glob(["**"], exclude = ["**/.git/**"]),
    visibility = ["//visibility:public"],
)
"""

def _llvm_repository_impl(ctx):
    git = ctx.which("git")
    if git == None:
        fail("git not found on PATH")

    def git_run(args, timeout = 600):
        res = ctx.execute([git] + args, timeout = timeout)
        if res.return_code != 0:
            fail("git %s failed:\n%s%s" % (" ".join(args), res.stdout, res.stderr))
        return res

    git_run(["init", "-q", "."])
    git_run(["remote", "add", "origin", ctx.attr.remote])
    git_run(["config", "extensions.partialClone", "origin"])
    git_run(["sparse-checkout", "set", "--cone"] + ctx.attr.sparse_paths)
    git_run(
        ["fetch", "-q", "--depth", "1", "--filter=blob:none", "origin", "refs/tags/" + ctx.attr.tag],
        timeout = 1800,
    )
    git_run(["checkout", "-q", "FETCH_HEAD"])

    got = git_run(["rev-parse", "HEAD"]).stdout.strip()
    if got != ctx.attr.commit:
        fail("pinned SHA mismatch: got %s, expected %s" % (got, ctx.attr.commit))

    for patch in ctx.attr.patches:
        git_run(["apply", str(ctx.path(patch))])

    ctx.delete("llvm/test/tools/llvm-cas/Inputs/self")
    ctx.file("BUILD.bazel", _BUILD_FILE, executable = False)

llvm_repository = repository_rule(
    implementation = _llvm_repository_impl,
    attrs = {
        "remote": attr.string(mandatory = True),
        "tag": attr.string(mandatory = True),
        "commit": attr.string(mandatory = True),
        "sparse_paths": attr.string_list(mandatory = True),
        "patches": attr.label_list(allow_files = [".patch"]),
    },
)

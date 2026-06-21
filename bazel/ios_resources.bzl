"""Collect the iossim JIT artifacts (server.o, the LLVM TargetProcess static
libs, and liborc_rt_iossim.a) into one directory, so IOSHostBuilder can point
the iOS host-app link at a single resource dir."""

def _ios_jit_resources_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    files = []
    for src in ctx.attr.srcs:
        files.extend(src[DefaultInfo].files.to_list())
    wanted = [f for f in files if f.extension in ("a", "o")]

    args = ctx.actions.args()
    args.add(out.path)
    args.add_all([f.path for f in wanted])
    ctx.actions.run_shell(
        inputs = wanted,
        outputs = [out],
        arguments = [args],
        command = 'set -e; d="$1"; shift; mkdir -p "$d"; for f in "$@"; do cp "$f" "$d/$(basename "$f")"; done',
    )
    return [DefaultInfo(files = depset([out]))]

ios_jit_resources = rule(
    implementation = _ios_jit_resources_impl,
    attrs = {
        "srcs": attr.label_list(mandatory = True),
    },
)

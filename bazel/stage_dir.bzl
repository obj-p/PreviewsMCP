"""Stage the files under a source subdirectory into a declared directory, so a
foreign_cc cmake() target can reference that directory by label ($(execpath))
instead of hardcoding the bzlmod-canonical external repo path."""

def _stage_dir_impl(ctx):
    out = ctx.actions.declare_directory(ctx.label.name)
    marker = "/" + ctx.attr.subdir + "/"
    files = [f for f in ctx.files.srcs if marker in f.path]
    if not files:
        fail("stage_dir: no files found under '%s'" % ctx.attr.subdir)

    args = ctx.actions.args()
    args.add(out.path)
    args.add(ctx.attr.subdir)
    args.add_all([f.path for f in files])
    ctx.actions.run_shell(
        inputs = files,
        outputs = [out],
        arguments = [args],
        command = """set -e
out="$1"; sub="$2"; shift 2
for f in "$@"; do
  rel="${f##*/$sub/}"
  mkdir -p "$out/$(dirname "$rel")"
  cp "$f" "$out/$rel"
done""",
    )
    return [DefaultInfo(files = depset([out]))]

stage_dir = rule(
    implementation = _stage_dir_impl,
    attrs = {
        "srcs": attr.label_list(mandatory = True, allow_files = True),
        "subdir": attr.string(mandatory = True),
    },
)

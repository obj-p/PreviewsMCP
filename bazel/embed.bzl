"""Embed the iOS host-app artifacts into a generated Swift source.

Replaces the EmbedHostAppSource SPM build-tool plugin. base64-encodes
HostApp.swift, Info.plist, and AppIcon.png into IOSHostAppSource.generated.swift,
consumed by PreviewsIOS. The static header/footer come from byte-exact template
fragments so the output matches the plugin's; only the base64 payloads vary.
"""

def _embed_host_app_source_impl(ctx):
    out = ctx.actions.declare_file(ctx.attr.out)
    ctx.actions.run_shell(
        inputs = [
            ctx.file.host_app,
            ctx.file.info_plist,
            ctx.file.app_icon,
            ctx.file.header,
            ctx.file.footer,
        ],
        outputs = [out],
        arguments = [
            ctx.file.host_app.path,
            ctx.file.info_plist.path,
            ctx.file.app_icon.path,
            ctx.file.header.path,
            ctx.file.footer.path,
            out.path,
        ],
        command = """
set -eu
host=$(base64 < "$1" | tr -d '\\n')
plist=$(base64 < "$2" | tr -d '\\n')
icon=$(base64 < "$3" | tr -d '\\n')
{
  cat "$4"
  printf 'private let _hostAppCodeBase64 = "%s"\\n' "$host"
  printf 'private let _infoPlistBase64 = "%s"\\n' "$plist"
  printf 'private let _iconBase64 = "%s"\\n' "$icon"
  cat "$5"
} > "$6"
""",
    )
    return [DefaultInfo(files = depset([out]))]

embed_host_app_source = rule(
    implementation = _embed_host_app_source_impl,
    attrs = {
        "host_app": attr.label(allow_single_file = True, mandatory = True),
        "info_plist": attr.label(allow_single_file = True, mandatory = True),
        "app_icon": attr.label(allow_single_file = True, mandatory = True),
        "header": attr.label(allow_single_file = True, default = "//bazel/embed:header.swift"),
        "footer": attr.label(allow_single_file = True, default = "//bazel/embed:footer.swift"),
        "out": attr.string(default = "IOSHostAppSource.generated.swift"),
    },
)

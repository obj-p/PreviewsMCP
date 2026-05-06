import Foundation
import PackagePlugin

/// Build-tool plugin that embeds the iOS host-app artifacts
/// (`HostAppSource/HostApp.swift`, `Info.plist`, `AppIcon.png`) into a
/// single Swift source file consumed by `PreviewsIOS`.
///
/// Lives in `HostAppSource/` at the package root rather than under
/// `Sources/` so SPM doesn't try to compile the iOS-only host-app
/// source as a macOS Swift target. The plugin reads the bytes; the
/// generated file exposes `IOSHostAppSource.code`, `.infoPlist`, and
/// `IOSAppIconData.bytes` with byte-equivalent runtime values to the
/// prior hand-written stringified versions. See `IOSHostBuilderHashTests`
/// for the gate.
@main
struct EmbedHostAppSource: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let hostAppDir = context.package.directoryURL.appending(path: "HostAppSource")
        let hostAppSwift = hostAppDir.appending(path: "HostApp.swift")
        let infoPlist = hostAppDir.appending(path: "Info.plist")
        let appIconPng = hostAppDir.appending(path: "AppIcon.png")
        let output = context.pluginWorkDirectoryURL.appending(path: "IOSHostAppSource.generated.swift")

        return [
            .buildCommand(
                displayName: "Embed iOS host-app source",
                executable: try context.tool(named: "EmbedHostAppSourceTool").url,
                arguments: [
                    hostAppSwift.path(),
                    infoPlist.path(),
                    appIconPng.path(),
                    output.path(),
                ],
                inputFiles: [hostAppSwift, infoPlist, appIconPng],
                outputFiles: [output]
            )
        ]
    }
}

import Foundation
import PackagePlugin

/// Build-tool plugin that embeds the iOS host-app artifacts
/// (`ios-host/app/HostApp.swift`, `Info.plist`, `AppIcon.png`) into a
/// single Swift source file consumed by `PreviewsIOS`.
///
/// Lives in `ios-host/app/` at the package root rather than under
/// `Sources/` so SPM doesn't try to compile the iOS-only host-app
/// source as a macOS Swift target. The plugin reads the bytes; the
/// generated file exposes `IOSHostAppSource.code`, `.infoPlist`, and
/// `IOSAppIconData.bytes` with byte-equivalent runtime values to the
/// prior hand-written stringified versions. See `IOSHostBuilderHashTests`
/// for the gate.
///
/// Assumes the plugin runs only inside the PreviewsMCP package itself —
/// `context.package.directoryURL` resolves to whatever package is
/// being built, so if PreviewsMCP ever becomes a SwiftPM dependency
/// of another package, the path lookup would land in the consumer's
/// root, not ours. Safe today; revisit if extracting `PreviewsCore`
/// as a public library.
@main
struct EmbedHostAppSource: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let hostAppDir = context.package.directoryURL.appending(path: "ios-host/app")
        let hostAppSwift = hostAppDir.appending(path: "HostApp.swift")
        let infoPlist = hostAppDir.appending(path: "Info.plist")
        let appIconPng = hostAppDir.appending(path: "AppIcon.png")
        let shellDir = hostAppDir.appending(path: "Shell")
        let shellSource = shellDir.appending(path: "ShellMain.m")
        let shellInfoPlist = shellDir.appending(path: "Info.plist")
        let shellEntitlements = shellDir.appending(path: "Shell.entitlements")
        let shellIconPng = shellDir.appending(path: "AppIcon.png")
        let output = context.pluginWorkDirectoryURL.appending(path: "IOSHostAppSource.generated.swift")

        return [
            .buildCommand(
                displayName: "Embed iOS host-app source",
                executable: try context.tool(named: "EmbedHostAppSourceTool").url,
                arguments: [
                    hostAppSwift.path(),
                    infoPlist.path(),
                    appIconPng.path(),
                    shellSource.path(),
                    shellInfoPlist.path(),
                    shellEntitlements.path(),
                    shellIconPng.path(),
                    output.path(),
                ],
                inputFiles: [
                    hostAppSwift, infoPlist, appIconPng,
                    shellSource, shellInfoPlist, shellEntitlements, shellIconPng,
                ],
                outputFiles: [output]
            )
        ]
    }
}

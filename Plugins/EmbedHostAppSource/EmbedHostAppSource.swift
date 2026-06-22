import Foundation
import PackagePlugin

/// Build-tool plugin that embeds the iOS agent-app artifacts
/// (`ios-host/agent/AgentApp.swift`, `Info.plist`, `AppIcon.png`) and the
/// shell-app artifacts (`ios-host/shell/*`) into a single Swift source file
/// consumed by `PreviewsIOS`.
///
/// The sources live under `ios-host/` at the package root rather than under
/// `Sources/` so SPM doesn't try to compile the iOS-only agent-app
/// source as a macOS Swift target. The plugin reads the bytes; the
/// generated file exposes `IOSAgentAppSource.code`, `.infoPlist`, and
/// `IOSAppIconData.bytes` with byte-equivalent runtime values to the
/// prior hand-written stringified versions. See `IOSAgentBuilderHashTests`
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
        let agentDir = context.package.directoryURL.appending(path: "ios-host/agent")
        let agentSource = agentDir.appending(path: "AgentApp.swift")
        let infoPlist = agentDir.appending(path: "Info.plist")
        let appIconPng = agentDir.appending(path: "AppIcon.png")
        let shellDir = context.package.directoryURL.appending(path: "ios-host/shell")
        let shellSource = shellDir.appending(path: "ShellMain.m")
        let shellInfoPlist = shellDir.appending(path: "Info.plist")
        let shellEntitlements = shellDir.appending(path: "Shell.entitlements")
        let shellIconPng = shellDir.appending(path: "AppIcon.png")
        let output = context.pluginWorkDirectoryURL.appending(path: "IOSAgentAppSource.generated.swift")

        return [
            .buildCommand(
                displayName: "Embed iOS agent-app source",
                executable: try context.tool(named: "EmbedHostAppSourceTool").url,
                arguments: [
                    agentSource.path(),
                    infoPlist.path(),
                    appIconPng.path(),
                    shellSource.path(),
                    shellInfoPlist.path(),
                    shellEntitlements.path(),
                    shellIconPng.path(),
                    output.path(),
                ],
                inputFiles: [
                    agentSource, infoPlist, appIconPng,
                    shellSource, shellInfoPlist, shellEntitlements, shellIconPng,
                ],
                outputFiles: [output]
            )
        ]
    }
}

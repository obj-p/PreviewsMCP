import Foundation
import PackagePlugin

@main
struct BundleIOSSimJIT: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let script = context.package.directoryURL
            .appending(path: "ios-host/executor/bundle.sh")
        let outputDir = context.pluginWorkDirectoryURL

        return [
            .prebuildCommand(
                displayName: "Bundle iossim JIT executor artifacts",
                executable: URL(fileURLWithPath: "/bin/bash"),
                arguments: [
                    script.path(),
                    context.package.directoryURL.path(),
                    outputDir.path(),
                ],
                outputFilesDirectory: outputDir
            )
        ]
    }
}

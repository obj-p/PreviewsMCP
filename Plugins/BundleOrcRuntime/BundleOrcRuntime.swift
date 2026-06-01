import Foundation
import PackagePlugin

@main
struct BundleOrcRuntime: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let archive = context.package.directoryURL
            .appending(path: "third_party/llvm-build-rt/lib/darwin/liborc_rt_osx.a")
        let outputDir = context.pluginWorkDirectoryURL
        let output = outputDir.appending(path: "liborc_rt_osx.a")

        return [
            .prebuildCommand(
                displayName: "Bundle orc runtime",
                executable: URL(fileURLWithPath: "/bin/cp"),
                arguments: [archive.path(), output.path()],
                outputFilesDirectory: outputDir
            )
        ]
    }
}

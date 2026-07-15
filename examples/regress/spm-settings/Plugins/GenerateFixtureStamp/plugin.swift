import PackagePlugin

@main
struct GenerateFixtureStamp: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws
        -> [Command]
    {
        let tool = try context.tool(named: "FixtureCodegen")
        let outputFile = context.pluginWorkDirectory.appending("GeneratedFixtureStamp.swift")

        return [
            .buildCommand(
                displayName: "Generate fixture build stamp for \(target.name)",
                executable: tool.path,
                arguments: [outputFile.string],
                outputFiles: [outputFile]
            ),
        ]
    }
}

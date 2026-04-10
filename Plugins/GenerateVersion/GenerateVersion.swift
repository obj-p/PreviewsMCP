import Foundation
import PackagePlugin

@main
struct GenerateVersion: BuildToolPlugin {
    func createBuildCommands(
        context: PluginContext,
        target: Target
    ) throws -> [Command] {
        let outputPath = context.pluginWorkDirectoryURL.appending(path: "GeneratedVersion.swift")
        let gitHeadURL = resolveGitHead(packageDir: context.package.directoryURL)
        return [
            .buildCommand(
                displayName: "Generate version from git tags",
                executable: try context.tool(named: "GenerateVersionTool").url,
                arguments: [
                    context.package.directoryURL.path(),
                    outputPath.path(),
                ],
                inputFiles: [gitHeadURL],
                outputFiles: [outputPath]
            )
        ]
    }

    /// Resolve the HEAD file path, handling both regular repos and worktrees.
    /// In a worktree, `.git` is a file containing `gitdir: <path>` — HEAD lives there.
    private func resolveGitHead(packageDir: URL) -> URL {
        let dotGit = packageDir.appending(path: ".git")
        // Check if .git is a file (worktree) or directory (normal repo)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDir), !isDir.boolValue,
            let contents = try? String(contentsOf: dotGit, encoding: .utf8),
            contents.hasPrefix("gitdir: ")
        {
            let gitDir = contents.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "gitdir: ", with: "")
            return URL(fileURLWithPath: gitDir).appending(path: "HEAD")
        }
        return dotGit.appending(path: "HEAD")
    }
}

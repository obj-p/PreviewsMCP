import Foundation

/// SPM (Swift Package Manager) build system integration.
public actor SPMBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL

    public init(projectRoot: URL, sourceFile: URL) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile
    }

    // MARK: - Detection

    public static func detect(for sourceFile: URL) async throws -> SPMBuildSystem? {
        var dir = sourceFile.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: "/")

        while dir.path != root.path {
            let packageSwift = dir.appendingPathComponent("Package.swift")
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: packageSwift.path, isDirectory: &isDir),
                !isDir.boolValue
            {
                return SPMBuildSystem(projectRoot: dir, sourceFile: sourceFile.standardizedFileURL)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Build

    public func build(platform: PreviewPlatform) async throws -> BuildContext {
        // 1. Describe the package to find the target
        let description = try await describePackage()
        let targetName = try findTarget(for: sourceFile, in: description)

        // 2. Resolve iOS SDK path once (used by both swift build and --show-bin-path)
        let iosSDKPath: String?
        if platform == .iOS {
            iosSDKPath = try await runProcess(
                "/usr/bin/xcrun", "--show-sdk-path", "--sdk", "iphonesimulator"
            )
        } else {
            iosSDKPath = nil
        }

        // 3. Build the package
        try await runSwiftBuild(platform: platform, iosSDKPath: iosSDKPath)

        // 4. Get build products path
        let binPath = try await showBinPath(platform: platform, iosSDKPath: iosSDKPath)

        // 5. Verify the module exists
        let modulesDir = binPath.appendingPathComponent("Modules")
        let swiftmodule = modulesDir.appendingPathComponent("\(targetName).swiftmodule")
        guard FileManager.default.fileExists(atPath: swiftmodule.path) else {
            throw BuildSystemError.missingArtifacts(
                "Expected \(targetName).swiftmodule at \(modulesDir.path)"
            )
        }

        // 6. Build compiler flags
        var flags: [String] = [
            "-I", modulesDir.path,
        ]

        // Add C module include paths for targets with C shims
        let targetBuildDir = binPath.appendingPathComponent("\(targetName).build")
        let includeDir = targetBuildDir.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: includeDir.path) {
            flags += ["-I", includeDir.path]
        }

        // 7. Collect Tier 2 data: other source files in the target
        let otherSourceFiles = try collectSourceFiles(
            targetName: targetName,
            in: description
        )

        return BuildContext(
            moduleName: targetName,
            compilerFlags: flags,
            projectRoot: projectRoot,
            targetName: targetName,
            sourceFiles: otherSourceFiles
        )
    }

    // MARK: - Private: Package Description

    private struct PackageDescription: Decodable {
        let name: String
        let targets: [Target]

        struct Target: Decodable {
            let name: String
            let type: String
            let path: String
            let sources: [String]?
        }
    }

    private func describePackage() async throws -> PackageDescription {
        let output = try await runProcess(
            "/usr/bin/env", "swift", "package", "describe", "--type", "json",
            workingDirectory: projectRoot
        )
        guard let data = output.data(using: .utf8) else {
            throw BuildSystemError.missingArtifacts("Could not parse package description")
        }
        return try JSONDecoder().decode(PackageDescription.self, from: data)
    }

    private func findTarget(
        for sourceFile: URL,
        in description: PackageDescription
    ) throws -> String {
        let filePath = sourceFile.path

        for target in description.targets {
            let targetDir = projectRoot.appendingPathComponent(target.path).standardizedFileURL.path
            if filePath.hasPrefix(targetDir + "/") || filePath == targetDir {
                return target.name
            }
        }

        throw BuildSystemError.targetNotFound(
            sourceFile: sourceFile.lastPathComponent,
            project: description.name
        )
    }

    // MARK: - Private: Build

    private func runSwiftBuild(platform: PreviewPlatform, iosSDKPath: String?) async throws {
        var args = ["swift", "build"]

        if platform == .iOS, let sdkPath = iosSDKPath {
            args += ["--triple", "arm64-apple-ios17.0-simulator", "--sdk", sdkPath]
        }

        try await runProcess("/usr/bin/env", args: args, workingDirectory: projectRoot)
    }

    private func showBinPath(platform: PreviewPlatform, iosSDKPath: String?) async throws -> URL {
        var args = ["swift", "build", "--show-bin-path"]

        if platform == .iOS, let sdkPath = iosSDKPath {
            args += ["--triple", "arm64-apple-ios17.0-simulator", "--sdk", sdkPath]
        }

        let output = try await runProcess(
            "/usr/bin/env", args: args, workingDirectory: projectRoot
        )
        return URL(fileURLWithPath: output)
    }

    // MARK: - Private: Source Files (Tier 2)

    /// Collect all .swift source files in the target EXCEPT the preview file.
    /// These are compiled alongside the transformed preview file so all types are visible.
    private func collectSourceFiles(
        targetName: String,
        in description: PackageDescription
    ) throws -> [URL]? {
        guard let target = description.targets.first(where: { $0.name == targetName }) else {
            return nil
        }

        let targetDir = projectRoot.appendingPathComponent(target.path).standardizedFileURL

        // Enumerate .swift files in the target directory
        guard
            let enumerator = FileManager.default.enumerator(
                at: targetDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return nil
        }

        var sourceFiles: [URL] = []
        for case let fileURL as URL in enumerator {
            guard fileURL.pathExtension == "swift" else { continue }
            let standardized = fileURL.standardizedFileURL
            // Exclude the preview file — it's compiled separately with ThunkGenerator
            if standardized.path != sourceFile.path {
                sourceFiles.append(standardized)
            }
        }

        return sourceFiles.isEmpty ? nil : sourceFiles
    }

    // MARK: - Private: Process Execution

    @discardableResult
    private func runProcess(_ executable: String, _ args: String..., workingDirectory: URL? = nil) async throws
        -> String
    {
        try await runProcess(executable, args: args, workingDirectory: workingDirectory)
    }

    @discardableResult
    private func runProcess(_ executable: String, args: [String], workingDirectory: URL? = nil) async throws -> String {
        let output = try await runAsync(executable, arguments: args, workingDirectory: workingDirectory)
        guard output.exitCode == 0 else {
            throw BuildSystemError.buildFailed(
                stderr: output.stderr.isEmpty ? output.stdout : output.stderr,
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }
}

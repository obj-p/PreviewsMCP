import Foundation

/// Bazel build system integration for rules_swift projects.
public actor BazelBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL

    public init(projectRoot: URL, sourceFile: URL) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile.standardizedFileURL
    }

    // MARK: - Detection

    /// Marker files that indicate a Bazel project root.
    static let projectMarkers = ["MODULE.bazel", "WORKSPACE.bazel", "WORKSPACE"]

    /// Marker files that indicate a Bazel package directory.
    static let packageMarkers = ["BUILD.bazel", "BUILD"]

    public static func detect(for sourceFile: URL) async throws -> BazelBuildSystem? {
        var dir = sourceFile.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: "/")

        while dir.path != root.path {
            for marker in projectMarkers {
                let markerFile = dir.appendingPathComponent(marker)
                var isDir: ObjCBool = false
                if FileManager.default.fileExists(atPath: markerFile.path, isDirectory: &isDir),
                    !isDir.boolValue
                {
                    // Verify bazel is actually available
                    guard await isBazelAvailable(in: dir) else { return nil }
                    return BazelBuildSystem(
                        projectRoot: dir, sourceFile: sourceFile.standardizedFileURL)
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Check if bazel is available by running `bazel version`.
    private static func isBazelAvailable(in directory: URL) async -> Bool {
        do {
            let output = try await runAsync(
                "/usr/bin/env", arguments: ["bazel", "version"],
                workingDirectory: directory, discardStderr: true)
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Build

    public func build(platform: PreviewPlatform) async throws -> BuildContext {
        // 1. Find the Bazel package and owning target
        let packagePath = try findBazelPackage(for: sourceFile)
        let sourceLabel = buildSourceLabel(packagePath: packagePath, sourceFile: sourceFile)
        let target = try await findOwningTarget(packagePath: packagePath, sourceLabel: sourceLabel)

        // 2. Get module name
        let moduleName = try await queryModuleName(target: target)

        // 3. Build the target
        try await runBazelBuild(target: target, platform: platform)

        // 4. Locate the .swiftmodule
        let compilerFlags = try await findCompilerFlags(
            target: target, moduleName: moduleName, platform: platform)

        // 5. Collect source files for Tier 2
        let sourceFiles = try await collectSourceFiles(target: target)

        return BuildContext(
            moduleName: moduleName,
            compilerFlags: compilerFlags,
            projectRoot: projectRoot,
            targetName: moduleName,
            sourceFiles: sourceFiles
        )
    }

    // MARK: - Private: Package Detection

    /// Walk up from the source file to find the nearest BUILD.bazel or BUILD file.
    /// Returns the package path relative to the project root.
    func findBazelPackage(for file: URL) throws -> String {
        var dir = file.deletingLastPathComponent().standardizedFileURL
        let rootPath = projectRoot.standardizedFileURL.path

        while dir.path.hasPrefix(rootPath) {
            for marker in Self.packageMarkers {
                let markerFile = dir.appendingPathComponent(marker)
                if FileManager.default.fileExists(atPath: markerFile.path) {
                    // Package path is relative to project root
                    let relativePath = String(dir.path.dropFirst(rootPath.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                    return relativePath
                }
            }
            dir = dir.deletingLastPathComponent()
        }

        throw BuildSystemError.targetNotFound(
            sourceFile: file.lastPathComponent,
            project: projectRoot.lastPathComponent
        )
    }

    /// Construct a Bazel label for a source file within a package.
    /// E.g., packagePath="Sources/ToDo", sourceFile=".../ToDoView.swift" → "//Sources/ToDo:ToDoView.swift"
    nonisolated func buildSourceLabel(packagePath: String, sourceFile: URL) -> String {
        let packageDir = projectRoot.appendingPathComponent(packagePath).standardizedFileURL
        let filePath = sourceFile.standardizedFileURL.path
        let packageDirPath = packageDir.path

        // The file component is the relative path from the package directory
        let fileComponent: String
        if filePath.hasPrefix(packageDirPath + "/") {
            fileComponent = String(filePath.dropFirst(packageDirPath.count + 1))
        } else {
            fileComponent = sourceFile.lastPathComponent
        }

        return "//\(packagePath):\(fileComponent)"
    }

    // MARK: - Private: Target Discovery

    /// Find the swift_library target that owns the source file using a package-scoped query.
    private func findOwningTarget(packagePath: String, sourceLabel: String) async throws -> String {
        let query =
            "kind(\"swift_library\", rdeps(//\(packagePath):all, \(sourceLabel)))"

        let output = try await runBazelQuery(query)
        let targets = output.split(separator: "\n").map(String.init)

        guard let target = targets.first else {
            throw BuildSystemError.targetNotFound(
                sourceFile: sourceFile.lastPathComponent,
                project: projectRoot.lastPathComponent
            )
        }

        return target
    }

    // MARK: - Private: Module Name

    /// Query the module_name attribute of a target. Falls back to the target name.
    private func queryModuleName(target: String) async throws -> String {
        let output = try await runBazelQuery("\(target)", outputFormat: "build")

        // Parse module_name from the build output: module_name = "ToDo",
        if let range = output.range(of: #"module_name\s*=\s*"([^"]+)""#, options: .regularExpression) {
            let match = output[range]
            // Extract the quoted value
            if let quoteStart = match.range(of: "\""),
                let quoteEnd = match.range(of: "\"", options: .backwards, range: quoteStart.upperBound..<match.endIndex)
            {
                return String(match[quoteStart.upperBound..<quoteEnd.lowerBound])
            }
        }

        // Fall back to target name (last component after ":")
        if let colonIndex = target.lastIndex(of: ":") {
            return String(target[target.index(after: colonIndex)...])
        }

        // Last resort: use the last path component
        return target.split(separator: "/").last.map(String.init) ?? target
    }

    // MARK: - Private: Build

    private func runBazelBuild(target: String, platform: PreviewPlatform) async throws {
        var args = ["bazel", "build", target]
        args += platformFlags(for: platform)
        try await runBazel(args)
    }

    // MARK: - Private: Artifact Discovery

    /// Locate the .swiftmodule and return compiler flags (`-I <dir>`).
    private func findCompilerFlags(
        target: String, moduleName: String, platform: PreviewPlatform
    ) async throws -> [String] {
        var args = ["bazel", "cquery", "--output=files", target]
        args += platformFlags(for: platform)

        let output = try await runBazel(args, discardStderr: true)

        // Find the .swiftmodule file in the output
        let files = output.split(separator: "\n").map(String.init)
        let swiftmoduleFile = files.first { $0.hasSuffix(".swiftmodule") }

        if let swiftmodulePath = swiftmoduleFile {
            // Resolve to absolute path (cquery may return relative paths from execroot)
            let absolutePath: URL
            if swiftmodulePath.hasPrefix("/") {
                absolutePath = URL(fileURLWithPath: swiftmodulePath)
            } else {
                absolutePath = projectRoot.appendingPathComponent(swiftmodulePath)
            }
            return ["-I", absolutePath.deletingLastPathComponent().path]
        }

        // Fallback: try bazel-bin symlink + package path
        let bazelBin = projectRoot.appendingPathComponent("bazel-bin")
        let moduleDir = bazelBin.appendingPathComponent(
            target.replacingOccurrences(of: "//", with: "")
                .split(separator: ":").first.map(String.init) ?? "")
        let swiftmodule = moduleDir.appendingPathComponent("\(moduleName).swiftmodule")

        guard FileManager.default.fileExists(atPath: swiftmodule.path) else {
            throw BuildSystemError.missingArtifacts(
                "Expected \(moduleName).swiftmodule in bazel-bin output for \(target)")
        }

        return ["-I", moduleDir.path]
    }

    // MARK: - Private: Source Files (Tier 2)

    /// Collect all source files for the target, excluding the preview file.
    private func collectSourceFiles(target: String) async throws -> [URL]? {
        let output: String
        do {
            output = try await runBazelQuery("labels(srcs, \(target))")
        } catch {
            // If query fails, fall back to Tier 1 (no source files)
            return nil
        }

        let labels = output.split(separator: "\n").map(String.init)
        var sourceFiles: [URL] = []

        for label in labels {
            guard let path = labelToPath(label) else { continue }
            let url = projectRoot.appendingPathComponent(path).standardizedFileURL
            // Exclude the preview file
            if url.path != sourceFile.path {
                sourceFiles.append(url)
            }
        }

        return sourceFiles.isEmpty ? nil : sourceFiles
    }

    /// Convert a Bazel label like "//Sources/ToDo:Item.swift" to a relative path "Sources/ToDo/Item.swift".
    nonisolated func labelToPath(_ label: String) -> String? {
        var label = label
        // Strip leading "//" or "@//"
        if let atSlashRange = label.range(of: "@//") {
            label = String(label[atSlashRange.upperBound...])
        } else if label.hasPrefix("//") {
            label = String(label.dropFirst(2))
        } else {
            return nil
        }

        // Split on ":" — package:file
        guard let colonIndex = label.firstIndex(of: ":") else { return nil }

        let packagePath = String(label[label.startIndex..<colonIndex])
        let fileName = String(label[label.index(after: colonIndex)...])

        if packagePath.isEmpty {
            return fileName
        }
        return "\(packagePath)/\(fileName)"
    }

    // MARK: - Private: Platform Flags

    private func platformFlags(for platform: PreviewPlatform) -> [String] {
        switch platform {
        case .macOS:
            return []
        case .iOSSimulator:
            return ["--platforms=@apple_support//platforms:ios_sim_arm64"]
        }
    }

    // MARK: - Private: Process Execution

    private func runBazelQuery(_ query: String, outputFormat: String? = nil) async throws -> String {
        var args = ["bazel", "query", query]
        if let format = outputFormat {
            args += ["--output=\(format)"]
        }
        return try await runBazel(args, discardStderr: true)
    }

    /// Run a bazel command via `/usr/bin/env`, check exit code, and return stdout.
    @discardableResult
    private func runBazel(
        _ arguments: [String], discardStderr: Bool = false
    ) async throws -> String {
        let output = try await runAsync(
            "/usr/bin/env", arguments: arguments,
            workingDirectory: projectRoot, discardStderr: discardStderr)
        guard output.exitCode == 0 else {
            throw BuildSystemError.buildFailed(
                stderr: output.stderr.isEmpty ? output.stdout : output.stderr,
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }
}

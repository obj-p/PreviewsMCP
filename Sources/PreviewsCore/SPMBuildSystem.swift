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

        // 6. Archive dependency targets into libDep.a files.
        //    SPM leaves library targets as loose .o files under <Dep>.build/ instead
        //    of creating .a archives, and .swiftmodule files don't carry autolink
        //    hints (no -module-link-name), so we have to make the archives ourselves
        //    and pass -l<Dep> explicitly below.
        let dependencyLibs = try await archiveDependencyTargets(
            binPath: binPath,
            consumerTargetName: targetName
        )

        // 7. Build compiler flags
        //    -I <Modules>   resolves dependency .swiftmodule files at compile time
        //    -L <binPath>   library search path for the archives created above
        //    -l<Dep>        per-dependency archive (lazy archive linking means only
        //                   object files actually referenced get pulled in)
        var flags: [String] = [
            "-I", modulesDir.path,
        ]
        if !dependencyLibs.isEmpty {
            flags += ["-L", binPath.path]
            for dep in dependencyLibs {
                flags += ["-l\(dep)"]
            }
        }

        // Add C module include paths for targets with C shims
        let targetBuildDir = binPath.appendingPathComponent("\(targetName).build")
        let includeDir = targetBuildDir.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: includeDir.path) {
            flags += ["-I", includeDir.path]
        }

        // 8. Collect Tier 2 data: other source files in the target
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
            args += ["--triple", PreviewPlatform.iOS.targetTriple, "--sdk", sdkPath]
        }

        try await runProcess("/usr/bin/env", args: args, workingDirectory: projectRoot)
    }

    private func showBinPath(platform: PreviewPlatform, iosSDKPath: String?) async throws -> URL {
        var args = ["swift", "build", "--show-bin-path"]

        if platform == .iOS, let sdkPath = iosSDKPath {
            args += ["--triple", PreviewPlatform.iOS.targetTriple, "--sdk", sdkPath]
        }

        let output = try await runProcess(
            "/usr/bin/env", args: args, workingDirectory: projectRoot
        )
        return URL(fileURLWithPath: output)
    }

    // MARK: - Private: Dependency Archives

    /// Archive every non-consumer target's `.o` files into `<binPath>/lib<Target>.a`
    /// and return the list of target names (for use with `-l<Target>`).
    ///
    /// SPM's `swift build` produces loose object files under `<binPath>/<Target>.build/`
    /// for each library target without creating a static archive, and doesn't emit
    /// autolink hints for them either. So the bridge compile can't discover or link
    /// dependency symbols on its own — we have to stage the archives ourselves.
    ///
    /// Consumer target `.build/` is skipped because Tier 2 already recompiles its
    /// sources directly. All other sibling targets (and transitively-built external
    /// packages, which land in the same bin path) are archived.
    private func archiveDependencyTargets(
        binPath: URL,
        consumerTargetName: String
    ) async throws -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: binPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }

        let arPath = try await Self.resolvedArPath()
        var libs: [String] = []

        for entry in entries {
            // We want `<binPath>/<Target>.build/` directories.
            let name = entry.lastPathComponent
            guard name.hasSuffix(".build") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let targetName = String(name.dropLast(".build".count))
            // Skip the consumer target — Tier 2 compiles its sources directly, and
            // archiving them here would cause duplicate-symbol errors at link time.
            if targetName == consumerTargetName { continue }
            // Skip SPM's own plugin/support bundles if any.
            if targetName.hasPrefix("_") { continue }

            // Collect .o files produced for this target.
            let objectFiles = collectObjectFiles(in: entry)
            guard !objectFiles.isEmpty else { continue }

            // Write to a temp file and atomically rename to avoid a race where a
            // concurrent compile reads the archive between delete and recreate.
            let archivePath = binPath.appendingPathComponent("lib\(targetName).a")
            let tmpArchivePath = binPath.appendingPathComponent("lib\(targetName).a.tmp")
            try? fm.removeItem(at: tmpArchivePath)

            var arArgs = ["rcs", tmpArchivePath.path]
            arArgs.append(contentsOf: objectFiles.map(\.path))
            let result = try await runAsync(arPath, arguments: arArgs)
            guard result.exitCode == 0 else {
                try? fm.removeItem(at: tmpArchivePath)
                throw BuildSystemError.buildFailed(
                    stderr: "ar failed for \(targetName): \(result.stderr)",
                    exitCode: result.exitCode
                )
            }
            // Atomic rename: the archive is never absent from the perspective of
            // a concurrent linker that reads it between two archiveDependencyTargets calls.
            _ = try? fm.replaceItemAt(archivePath, withItemAt: tmpArchivePath)
            libs.append(targetName)
        }

        return libs
    }

    /// Recursively collect `.o` files under a target's build directory, including
    /// files named `Foo.swift.o` that swift build emits for Swift sources.
    private func collectObjectFiles(in directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "o" {
            files.append(url)
        }
        return files
    }

    private static func resolvedArPath() async throws -> String {
        let output = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--find", "ar"], discardStderr: true)
        guard output.exitCode == 0 else {
            throw BuildSystemError.missingArtifacts("Could not locate `ar` via xcrun")
        }
        return output.stdout
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

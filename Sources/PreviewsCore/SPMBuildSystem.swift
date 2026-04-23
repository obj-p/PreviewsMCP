import Foundation

/// SPM (Swift Package Manager) build system integration.
public actor SPMBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL

    public init(projectRoot: URL, sourceFile: URL) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile
    }

    // MARK: - Platform Detection

    /// Detect platforms declared in the SPM package containing this source file.
    /// Returns nil if no SPM package found or platforms can't be determined.
    /// Runs synchronously (short-lived subprocess) for use in CLI resolution.
    public static func detectPlatforms(for sourceFile: URL) -> [String]? {
        guard let packageDir = findPackageDirectory(from: sourceFile) else { return nil }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["swift", "package", "describe", "--type", "json"]
        process.currentDirectoryURL = packageDir
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
        } catch { return nil }

        // Kill the process if it doesn't finish in 10 seconds (e.g., network
        // stall during dependency resolution on CI).
        let proc = process
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if proc.isRunning { proc.terminate() }
        }

        // Read pipe data BEFORE waitUntilExit to avoid deadlock.
        // If the subprocess writes more than the pipe buffer (~64KB),
        // it blocks until the parent drains the pipe. Calling
        // waitUntilExit first would deadlock both sides.
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return decodePlatforms(from: data)
    }

    /// Async variant of `detectPlatforms` that avoids blocking the cooperative thread pool.
    /// Preferred in async contexts like the MCP server.
    public static func detectPlatformsAsync(for sourceFile: URL) async -> [String]? {
        guard let packageDir = findPackageDirectory(from: sourceFile) else { return nil }

        guard
            let output = try? await runAsync(
                "/usr/bin/env",
                arguments: ["swift", "package", "describe", "--type", "json"],
                workingDirectory: packageDir,
                discardStderr: true
            ),
            output.exitCode == 0,
            let data = output.stdout.data(using: .utf8)
        else { return nil }
        return decodePlatforms(from: data)
    }

    /// Walk up from a source file to find the nearest directory containing
    /// Package.swift — but only if the source file is genuinely part of that
    /// SPM package. If the walk crosses an `.xcodeproj`, `.xcworkspace`, or
    /// Bazel workspace first, the source belongs to that non-SPM project and
    /// we return nil rather than falsely attributing it to an outer SPM
    /// package (which for a repo containing `examples/xcodeproj/...` would
    /// incorrectly pick the repo's own Package.swift and then run
    /// `swift package describe` on it — expensive and pointless).
    public static func findPackageDirectory(from sourceFile: URL) -> URL? {
        let fm = FileManager.default
        var dir = sourceFile.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: "/")
        while dir.path != root.path {
            // If this directory looks like (or sits inside) a non-SPM project,
            // stop before finding an outer Package.swift.
            if directoryContainsNonSPMProject(dir, fm: fm) {
                return nil
            }

            let packageSwift = dir.appendingPathComponent("Package.swift")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: packageSwift.path, isDirectory: &isDir),
                !isDir.boolValue
            {
                return dir
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// True if the given directory contains a file/folder that marks it as a
    /// non-SPM project (xcodeproj, xcworkspace, Bazel WORKSPACE/BUILD).
    private static func directoryContainsNonSPMProject(
        _ dir: URL, fm: FileManager
    ) -> Bool {
        guard
            let entries = try? fm.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else { return false }
        for entry in entries {
            let name = entry.lastPathComponent
            if name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace") {
                return true
            }
            if name == "WORKSPACE" || name == "WORKSPACE.bazel"
                || name == "MODULE.bazel"
            {
                return true
            }
        }
        return false
    }

    /// Returns .iOS if the SPM package declares iOS but not macOS; nil otherwise.
    /// Convenience for the common "should we default to iOS?" check at CLI/MCP call sites.
    public static func inferredPlatform(for sourceFile: URL) -> PreviewPlatform? {
        guard let platforms = detectPlatforms(for: sourceFile) else { return nil }
        if platforms.contains("ios"), !platforms.contains("macos") { return .iOS }
        return nil
    }

    /// Async variant of `inferredPlatform` for MCP server contexts.
    public static func inferredPlatformAsync(for sourceFile: URL) async -> PreviewPlatform? {
        guard let platforms = await detectPlatformsAsync(for: sourceFile) else { return nil }
        if platforms.contains("ios"), !platforms.contains("macos") { return .iOS }
        return nil
    }

    private static func decodePlatforms(from data: Data) -> [String]? {
        struct PlatformInfo: Decodable {
            let platforms: [PlatformEntry]?
            struct PlatformEntry: Decodable { let name: String }
        }
        guard let info = try? JSONDecoder().decode(PlatformInfo.self, from: data),
            let platforms = info.platforms, !platforms.isEmpty
        else { return nil }
        return platforms.map(\.name)
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

        // 6b. Discover binary XCFramework dependencies.
        //     SPM copies pre-built .framework bundles (from binaryTarget / XCFramework
        //     dependencies) directly into binPath. These aren't covered by the
        //     .build/-directory scan above — they need -F (framework search path)
        //     and -framework flags instead of -L/-l.
        let frameworkNames = collectFrameworks(binPath: binPath)

        // 7. Build compiler flags
        //    -I <Modules>   resolves dependency .swiftmodule files at compile time
        //    -L <binPath>   library search path for the archives created above
        //    -l<Dep>        per-dependency archive (lazy archive linking means only
        //                   object files actually referenced get pulled in)
        //    -F <binPath>   framework search path for binary XCFramework deps
        //    -framework X   link against a binary framework
        var flags: [String] = [
            "-I", modulesDir.path,
        ]
        if !dependencyLibs.isEmpty {
            flags += ["-L", binPath.path]
            for dep in dependencyLibs {
                flags += ["-l\(dep)"]
            }
        }
        if !frameworkNames.isEmpty {
            flags += ["-F", binPath.path]
            for fw in frameworkNames {
                flags += ["-framework", fw]
            }
            // Embed the framework search path as an rpath so dlopen can
            // find the framework at runtime (the dylib references it via
            // @rpath/Foo.framework/...).
            flags += ["-Xlinker", "-rpath", "-Xlinker", binPath.path]
        }

        // Add C module include paths for targets with C shims
        let targetBuildDir = binPath.appendingPathComponent("\(targetName).build")
        let includeDir = targetBuildDir.appendingPathComponent("include")
        if FileManager.default.fileExists(atPath: includeDir.path) {
            flags += ["-I", includeDir.path]
        }

        // Forward SPM's -package-name so package-access symbols from sibling
        // targets in the same package stay visible when the dylib recompiles.
        // The identity cannot be derived from Package.swift's `name:` — for
        // path packages SPM uses the directory basename lowercased — so we
        // read the exact value out of the LLBuild manifest that `swift build`
        // just wrote. Deriving the manifest path from `binPath` also covers
        // users who relocate `.build` via --scratch-path / SWIFTPM_BUILD_DIR.
        if let manifestPath = Self.manifestPath(forBinPath: binPath),
            let packageName = Self.readPackageName(
                fromManifestAt: manifestPath, forTarget: targetName)
        {
            flags += ["-package-name", packageName]
        }

        // 8. Collect Tier 2 data: other source files in the target
        var otherSourceFiles = try collectSourceFiles(
            targetName: targetName,
            in: description
        )

        // 8b. Union SPM-generated sources (e.g. resource_bundle_accessor.swift
        //     for targets with .process/.copy resources, which defines
        //     Bundle.module). Without these, previews that use Bundle.module
        //     fail to compile with "type 'Bundle' has no member 'module'".
        let generated = Self.collectGeneratedSources(
            binPath: binPath, targetName: targetName
        )
        if !generated.isEmpty {
            otherSourceFiles = (otherSourceFiles ?? []) + generated
        }

        return BuildContext(
            moduleName: targetName,
            compilerFlags: flags,
            projectRoot: projectRoot,
            targetName: targetName,
            sourceFiles: otherSourceFiles
        )
    }

    /// Collect SPM-generated Swift sources that swiftc would normally compile into
    /// the target. SPM writes these (currently `resource_bundle_accessor.swift` for
    /// targets with resources) to `<binPath>/<Target>.build/DerivedSources/` and
    /// never co-locates user sources there, so a shallow glob is safe. No filename
    /// whitelist — SPM has renamed the accessor across Swift versions and may add
    /// more generated files in the future.
    nonisolated static func collectGeneratedSources(
        binPath: URL, targetName: String
    ) -> [URL] {
        let derivedDir =
            binPath
            .appendingPathComponent("\(targetName).build")
            .appendingPathComponent("DerivedSources")
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: derivedDir,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            )
        else {
            return []
        }
        return
            entries
            .filter { $0.pathExtension == "swift" }
            .map { $0.standardizedFileURL }
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
        var args = ["build"]

        if platform == .iOS, let sdkPath = iosSDKPath {
            args += ["--triple", PreviewPlatform.iOS.targetTriple, "--sdk", sdkPath]
        }

        let result = try await SPMBuildRecovery.runSwift(
            arguments: args, workingDirectory: projectRoot
        )
        guard result.exitCode == 0 else {
            throw BuildSystemError.buildFailed(
                stderr: result.stderr.isEmpty ? result.stdout : result.stderr,
                exitCode: result.exitCode
            )
        }
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

    /// Decide whether to skip a `<Target>.build/` directory during dependency
    /// archiving. Three reasons to skip:
    ///
    /// 1. The target *is* the consumer — Tier 2 already recompiles its sources
    ///    directly; archiving them again would cause duplicate-symbol link errors.
    /// 2. Name starts with `_` — SPM's own plugin/support bundles.
    /// 3. SPM already produced `lib<Target>.dylib` in binPath (i.e. this is a
    ///    dynamic library product). Autolink via `-module-link-name` handles
    ///    linking from actual importers; a blanket `-l<Target>` would drag
    ///    test-only transitive deps (e.g. swift-issue-reporting's
    ///    `IssueReportingTestSupport`, which references `Testing.framework`)
    ///    into the preview host unconditionally. The simulator runtime doesn't
    ///    ship `Testing.framework`, so those deps then fail at dlopen.
    ///
    /// Binary-target XCFramework artifacts that land as bare `lib<X>.dylib`
    /// without a matching `<X>.build/` directory don't reach this predicate —
    /// the outer loop gates on `.build/` existing.
    nonisolated static func shouldSkipDependencyTarget(
        targetName: String,
        consumerTargetName: String,
        binPath: URL,
        fm: FileManager = .default
    ) -> Bool {
        if targetName == consumerTargetName { return true }
        if targetName.hasPrefix("_") { return true }
        let dylibPath = binPath.appendingPathComponent("lib\(targetName).dylib")
        return fm.fileExists(atPath: dylibPath.path)
    }

    /// Archive every non-consumer target's `.o` files into `<binPath>/lib<Target>.a`
    /// and return the list of target names (for use with `-l<Target>`).
    ///
    /// SPM's `swift build` produces loose object files under `<binPath>/<Target>.build/`
    /// for each library target without creating a static archive, and doesn't emit
    /// autolink hints for them either. So the bridge compile can't discover or link
    /// dependency symbols on its own — we have to stage the archives ourselves.
    ///
    /// Targets flagged by `shouldSkipDependencyTarget` are excluded: the consumer
    /// itself (Tier 2 recompiles it), SPM plugin bundles, and dynamic library
    /// products that Swift's autolink already handles.
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
            if Self.shouldSkipDependencyTarget(
                targetName: targetName,
                consumerTargetName: consumerTargetName,
                binPath: binPath,
                fm: fm
            ) {
                continue
            }

            // Collect .o files produced for this target.
            let objectFiles = collectObjectFiles(in: entry)
            guard !objectFiles.isEmpty else { continue }

            // Write to a unique temp file and atomically swap into place so a
            // concurrent linker never sees the archive as missing.
            let archivePath = binPath.appendingPathComponent("lib\(targetName).a")
            let tmpArchivePath = binPath.appendingPathComponent(
                "lib\(targetName).a.\(ProcessInfo.processInfo.globallyUniqueString).tmp")

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
            // replaceItemAt swaps atomically on APFS. Falls back to moveItem
            // when the archive doesn't exist yet (first build).
            do {
                _ = try fm.replaceItemAt(archivePath, withItemAt: tmpArchivePath)
            } catch {
                try fm.moveItem(at: tmpArchivePath, to: archivePath)
            }
            libs.append(targetName)
        }

        return libs
    }

    /// Collect `.framework` bundles in binPath (binary XCFramework dependencies).
    /// Returns the framework names (e.g. ["Lottie"]) for use with `-framework`.
    private func collectFrameworks(binPath: URL) -> [String] {
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

        var frameworks: [String] = []
        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".framework") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }
            let frameworkName = String(name.dropLast(".framework".count))
            frameworks.append(frameworkName)
        }
        return frameworks
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

    // MARK: - Private: Package Name (from build manifest)

    /// Locate SPM's LLBuild manifest given the build's bin path.
    /// Bin path is `<scratch>/<triple>/<config>/`; the manifest lives at
    /// `<scratch>/<config>.yaml`.
    static func manifestPath(forBinPath binPath: URL) -> URL? {
        let config = binPath.lastPathComponent
        guard !config.isEmpty else { return nil }
        let scratchDir = binPath.deletingLastPathComponent().deletingLastPathComponent()
        return scratchDir.appendingPathComponent("\(config).yaml")
    }

    /// Read the `-package-name` value SPM passed to swiftc for a given target
    /// out of the LLBuild manifest. Returns nil when the file is missing, the
    /// target's compile command can't be found, or the target has no
    /// `-package-name` flag (older toolchains).
    ///
    /// The manifest encodes each compile command on a single line like
    ///     args: [..., "-module-name","ToDo", ..., "-package-name","spm"]
    /// so we scan line-by-line for the one that matches our target and pull
    /// the adjacent package-name out. Anchoring the module-name match with
    /// surrounding quotes/commas is what keeps `ToDo` from colliding with
    /// `ToDoExtras`.
    static func readPackageName(fromManifestAt url: URL, forTarget target: String) -> String? {
        guard let data = try? Data(contentsOf: url),
            let contents = String(data: data, encoding: .utf8)
        else { return nil }

        let moduleNeedle = "\"-module-name\",\"\(target)\""
        let packageFlag = "\"-package-name\",\""

        for rawLine in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard line.hasPrefix("args: ["), line.contains(moduleNeedle) else { continue }
            // Fall through (not bail) when the matched line lacks -package-name:
            // SPM may emit more than one compile command per module (e.g. a
            // wrapper plus the real args line), and only the args line carries
            // the flag.
            guard let flagRange = line.range(of: packageFlag) else { continue }
            let tail = line[flagRange.upperBound...]
            guard let endQuote = tail.firstIndex(of: "\"") else { continue }
            return String(tail[..<endQuote])
        }
        return nil
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

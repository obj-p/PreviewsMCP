import Foundation

/// SPM (Swift Package Manager) build system integration.
public actor SPMBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL
    private var primedTarget: String?

    public init(projectRoot: URL, sourceFile: URL) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile
    }

    /// Hand over the target the ownership walk already confirmed, so build()
    /// does not run a second `swift package describe` to re-find it.
    func prime(targetName: String) {
        primedTarget = targetName
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

            if packageMarker(in: dir) != nil {
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
            if packageMarker(in: dir) != nil {
                return SPMBuildSystem(projectRoot: dir, sourceFile: sourceFile.standardizedFileURL)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// The Package.swift marker file in the given directory, if any.
    static func packageMarker(in directory: URL) -> URL? {
        let marker = directory.appendingPathComponent("Package.swift")
        var isDir: ObjCBool = false
        guard
            FileManager.default.fileExists(atPath: marker.path, isDirectory: &isDir),
            !isDir.boolValue
        else { return nil }
        return marker
    }

    // MARK: - Ownership

    /// Confirm membership against the package's own model: the target whose
    /// resolved `sources` list (post-exclusion) contains the file. Targets
    /// that omit `sources` fall back to path containment so a package that
    /// builds fine never turns into `notMember` on a missing field.
    static func confirmOwnership(
        projectRoot: URL, sourceFile: URL
    ) async -> OwnershipVerdict {
        let output: ProcessOutput
        do {
            output = try await runAsync(
                "/usr/bin/env",
                arguments: ["swift", "package", "describe", "--type", "json"],
                workingDirectory: projectRoot
            )
        } catch {
            return .indeterminate(
                reason: "swift package describe failed: \(error.localizedDescription)"
            )
        }
        guard output.exitCode == 0 else {
            let detail = output.stderr.split(separator: "\n").last.map(String.init) ?? ""
            return .indeterminate(
                reason: "swift package describe exited \(output.exitCode): \(detail)"
            )
        }
        guard
            let data = output.stdout.data(using: .utf8),
            let description = try? JSONDecoder().decode(PackageDescription.self, from: data)
        else {
            return .indeterminate(reason: "could not decode swift package describe output")
        }

        let filePath = sourceFile.standardizedFileURL.path
        for target in description.targets {
            let targetDir = projectRoot.appendingPathComponent(target.path).standardizedFileURL
            let member =
                if let sources = target.sources {
                    sources.contains {
                        targetDir.appendingPathComponent($0).standardizedFileURL.path == filePath
                    }
                } else {
                    filePath.hasPrefix(targetDir.path + "/") || filePath == targetDir.path
                }
            if member {
                return .confirmed(
                    Ownership(kind: .spm, projectRoot: projectRoot, targetName: target.name)
                )
            }
        }
        return .notMember(
            reason:
            "no target in package '\(description.name)' lists \(sourceFile.lastPathComponent)"
        )
    }

    // MARK: - Build

    public func build(platform: PreviewPlatform) async throws -> BuildContext {
        // 1. Describe the package to find the target (already answered by the
        //    ownership walk when this instance came from detection)
        let targetName: String = if let primedTarget {
            primedTarget
        } else {
            try findTarget(for: sourceFile, in: await describePackage())
        }

        // 2. Resolve iOS SDK path once (used by both swift build and --show-bin-path)
        let iosSDKPath: String? =
            platform == .iOS ? try await Toolchain.sdkPath(for: .iOS) : nil

        // 3. Build the package
        try await runSwiftBuild(platform: platform, iosSDKPath: iosSDKPath)

        // 4. Get build products path
        let binPath = try await showBinPath(platform: platform, iosSDKPath: iosSDKPath)

        // 5. Verify the module exists
        let modulesDir = binPath.appendingPathComponent("Modules")
        try BuildSystemSupport.verifySwiftModule(named: targetName, in: modulesDir) {
            BuildSystemError.missingArtifacts(
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
        let frameworkNames = BuildSystemSupport.collectFrameworks(binPath: binPath)

        // 7. Capture the compile command swift build actually ran for the
        //    target out of the llbuild manifest it just wrote. The normalized
        //    args carry the target's defines, language mode, feature flags,
        //    macro plugin loads, C module maps, search paths, and
        //    -package-name — everything the previous per-setting derivation
        //    dropped. Deriving the manifest path from `binPath` also covers
        //    users who relocate `.build` via --scratch-path / SWIFTPM_BUILD_DIR.
        guard let manifestPath = Self.manifestPath(forBinPath: binPath) else {
            throw BuildSystemError.missingArtifacts(
                "Could not locate the build manifest for \(binPath.path)"
            )
        }
        let manifestContents = try SPMCommandCapture.readManifest(at: manifestPath)
        let captured = try SPMCommandCapture.capture(
            contents: manifestContents, forTarget: targetName, manifestPath: manifestPath
        )
        var flags = CompileCommandNormalizer.normalize(captured.arguments)

        //    Link-time inputs are not part of the captured compile command:
        //    -L <binPath>   library search path for the archives created above
        //    -l<Dep>        per-dependency archive (lazy archive linking means only
        //                   object files actually referenced get pulled in)
        //    -F <binPath>   framework search path for binary XCFramework deps
        //    -framework X   link against a binary framework
        //    SPM also copies static binaryTarget archives (libX.a out of a
        //    static XCFramework slice) straight into binPath; scanning for
        //    lib*.a picks up both those and the archives created above.
        var linkLibs = dependencyLibs
        let binPathEntries =
            (try? FileManager.default.contentsOfDirectory(
                at: binPath, includingPropertiesForKeys: nil
            )) ?? []
        for entry in binPathEntries
            where entry.pathExtension == "a" && entry.lastPathComponent.hasPrefix("lib")
        {
            let name = String(
                entry.deletingPathExtension().lastPathComponent.dropFirst(3)
            )
            if !linkLibs.contains(name),
               !Self.shouldSkipDependencyTarget(
                   targetName: name, consumerTargetName: targetName, binPath: binPath
               )
            {
                linkLibs.append(name)
            }
        }
        if !linkLibs.isEmpty {
            flags += ["-L", binPath.path]
            for dep in linkLibs {
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

        // 8. Tier 2 sources are the captured compile inputs: exclusions
        //    already applied, resource accessors and plugin-generated sources
        //    already included. Only the preview file is held out (it is
        //    compiled separately with ThunkGenerator).
        let previewPath = sourceFile.standardizedFileURL.path
        let otherSourceFiles = captured.swiftInputs.filter { $0.path != previewPath }

        let evidence = Self.deriveEvidence(
            manifestContents: manifestContents,
            scratchDirectory: Self.scratchDirectory(forManifestPath: manifestPath),
            projectRoot: projectRoot
        )
        if let evidence {
            Log.info("spm \(evidence.logDescription)")
        }

        return BuildContext(
            moduleName: targetName,
            compilerFlags: flags,
            projectRoot: projectRoot,
            targetName: targetName,
            sourceFiles: otherSourceFiles.isEmpty ? nil : otherSourceFiles,
            evidence: evidence
        )
    }

    /// Derive the stage-3 EvidenceSet from the llbuild manifest: one
    /// source root per compile node (the target's and its local
    /// dependencies'; fetched dependencies live under the scratch dir and
    /// classify as products), `copy-tool` inputs as runtime resources,
    /// and the package manifests governing each root. The product root is
    /// the actual scratch directory — derived, not name-matched, so
    /// `--scratch-path` relocations stay covered.
    static func deriveEvidence(
        manifestContents: String, scratchDirectory: URL, projectRoot: URL
    ) -> EvidenceSet? {
        let raw = SPMCommandCapture.evidence(contents: manifestContents)
        let productRoots = [EvidenceClassifier.productRoot(scratchDirectory)]

        let roots = EvidenceClassifier.sourceRoots(
            forGroups: raw.compileNodeSwiftInputs, productRoots: productRoots
        )
        var definitions: Set<URL> = []
        for root in roots {
            if let manifest = nearestPackageManifest(above: root, productRoots: productRoots) {
                definitions.insert(manifest)
            }
        }

        let resources = raw.copyToolInputs.compactMap {
            EvidenceClassifier.evidencePath($0, productRoots: productRoots)
        }

        for name in ["Package.swift", "Package.resolved"] {
            if let file = EvidenceClassifier.evidencePath(
                projectRoot.appendingPathComponent(name), productRoots: productRoots
            ) {
                definitions.insert(file)
            }
        }

        return EvidenceSet.make(
            sourceDirectories: roots, runtimeInputs: resources, definitionFiles: definitions
        )
    }

    /// The scratch directory owning a build manifest (`<scratch>/<config>.yaml`).
    static func scratchDirectory(forManifestPath manifestPath: URL) -> URL {
        manifestPath.deletingLastPathComponent()
    }

    /// The `Package.swift` governing a source root, found by walking up
    /// a bounded number of levels (a target source dir sits at most a
    /// few levels below its package root).
    private static func nearestPackageManifest(
        above directory: URL, productRoots: [URL]
    ) -> URL? {
        var dir = directory
        for _ in 0 ..< 6 {
            if let manifest = EvidenceClassifier.evidencePath(
                dir.appendingPathComponent("Package.swift"), productRoots: productRoots
            ) {
                return manifest
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    // MARK: - Private: Package Description

    struct PackageDescription: Decodable {
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
        // Pin the build system that writes the llbuild manifest the compile
        // capture reads; SwiftPM's default is moving to Swift Build, which
        // does not emit it.
        var args = ["build", "--build-system", "native"]

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
        var args = ["swift", "build", "--build-system", "native", "--show-bin-path"]

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
    ///
    /// Assumes the SPM product name equals the target name (so the dylib SPM
    /// emits is `lib<Target>.dylib`). Covers the real-world repro
    /// (`IssueReportingTestSupport` is declared with matching product+target
    /// names) and every swift-issue-reporting-style layout we've seen. If a
    /// renamed dynamic product ever shows up here — `.library(name: "Foo",
    /// type: .dynamic, targets: ["Bar"])` — the predicate won't fire and the
    /// archive-then-link fallback runs against `Bar.build/`'s `.o` files,
    /// which is what happened before this fix; the original bug is specific
    /// to blanket `-l<Target>` resolving to `lib<Target>.dylib`, so the
    /// rename-mismatch case was always safe.
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

        let arPath = try await Toolchain.arPath()
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
            let objectFiles = BuildSystemSupport.collectObjectFiles(in: entry)
            guard !objectFiles.isEmpty else { continue }

            // Write to a unique temp file and atomically swap into place so a
            // concurrent linker never sees the archive as missing.
            let archivePath = binPath.appendingPathComponent("lib\(targetName).a")
            let tmpArchivePath = binPath.appendingPathComponent(
                "lib\(targetName).a.\(ProcessInfo.processInfo.globallyUniqueString).tmp"
            )

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

    // MARK: - Private: Build Manifest

    /// Locate SPM's LLBuild manifest given the build's bin path.
    /// Bin path is `<scratch>/<triple>/<config>/`; the manifest lives at
    /// `<scratch>/<config>.yaml`.
    static func manifestPath(forBinPath binPath: URL) -> URL? {
        let config = binPath.lastPathComponent
        guard !config.isEmpty else { return nil }
        let scratchDir = binPath.deletingLastPathComponent().deletingLastPathComponent()
        return scratchDir.appendingPathComponent("\(config).yaml")
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

import Foundation

/// Xcode build system integration for .xcodeproj and .xcworkspace projects.
public actor XcodeBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL
    private let projectFile: URL
    private let requestedScheme: String?
    private let confirmedTarget: String?

    /// The xcodebuild flag for referencing the project or workspace.
    private var xcodebuildFlag: String {
        projectFile.pathExtension == "xcworkspace" ? "-workspace" : "-project"
    }

    public init(
        projectRoot: URL,
        sourceFile: URL,
        projectFile: URL,
        requestedScheme: String? = nil,
        confirmedTarget: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile.standardizedFileURL
        self.projectFile = projectFile
        self.requestedScheme = requestedScheme
        self.confirmedTarget = confirmedTarget
    }

    // MARK: - Detection

    /// Find a .xcworkspace or .xcodeproj in the given directory.
    /// Prefers a .xcworkspace whose name matches a colocated .xcodeproj (standard Xcode convention),
    /// then falls back to any workspace, then any project.
    static func findXcodeProject(in directory: URL) -> URL? {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil
            )
        else { return nil }
        let workspaces = contents.filter { $0.pathExtension == "xcworkspace" }
        let projects = contents.filter { $0.pathExtension == "xcodeproj" }
        // Prefer a workspace whose stem matches a colocated .xcodeproj
        if let project = projects.first {
            let stem = project.deletingPathExtension().lastPathComponent
            if let matching = workspaces.first(where: {
                $0.deletingPathExtension().lastPathComponent == stem
            }) {
                return matching
            }
        }
        return workspaces.first ?? projects.first
    }

    // MARK: - Build

    public func build(platform: PreviewPlatform) async throws -> BuildContext {
        // 1. List schemes and pick one
        let projectInfo = try await listSchemes()
        let scheme = try pickScheme(from: projectInfo)

        // 2. Build the project (must happen before getBuildSettings so DerivedData is populated)
        let buildLog = try await runBuild(scheme: scheme, platform: platform)

        // 3. Get build settings (post-build so all paths are valid)
        let settings = try await getBuildSettings(scheme: scheme, platform: platform)

        let moduleName =
            settings["PRODUCT_MODULE_NAME"] ?? settings["TARGET_NAME"] ?? scheme
        let targetName = settings["TARGET_NAME"] ?? scheme

        // 4. Verify build products exist
        guard let builtProductsDir = settings["BUILT_PRODUCTS_DIR"] else {
            throw BuildSystemError.missingArtifacts(
                "BUILT_PRODUCTS_DIR not found in build settings for scheme \(scheme)"
            )
        }

        guard FileManager.default.fileExists(atPath: builtProductsDir) else {
            throw BuildSystemError.missingArtifacts(
                "Build products directory not found at \(builtProductsDir)"
            )
        }

        // 5. Capture the compile command xcodebuild actually ran; a
        //    build-with-Bazel project logs no SwiftDriver invocation, so the
        //    settings-derived path below stays as its fallback.
        let captured = try await captureCommand(
            buildLog: buildLog, scheme: scheme, platform: platform,
            moduleName: moduleName, builtProductsDir: builtProductsDir
        )
        if let captured {
            return try await buildContext(
                from: captured, settings: settings,
                moduleName: moduleName, targetName: targetName,
                builtProductsDir: builtProductsDir, platform: platform
            )
        }

        // 5-fallback. Collect source files for Tier 2 (from OutputFileMap.json)
        var sourceFiles = collectSourceFiles(settings: settings, targetName: targetName)

        // 5b. Union Xcode-generated Swift sources from DERIVED_FILE_DIR.
        //     OutputFileMap lists the swift-driver's input files only — it does
        //     NOT include files Xcode generates during the build (asset
        //     symbols, string catalog symbols, plist symbols, Core Data
        //     NSManagedObject subclasses, etc.). Without these, previews that
        //     reference Color.brandPrimary / Image.foo and friends fail to
        //     compile with "type 'Color' has no member 'brandPrimary'".
        if let derivedFileDir = settings["DERIVED_FILE_DIR"] {
            let generated = Self.collectGeneratedSources(
                derivedFileDir: URL(fileURLWithPath: derivedFileDir)
            )
            if !generated.isEmpty {
                sourceFiles = (sourceFiles ?? []) + generated
            }
        }

        // 5c. Rewrite any `Generated*Symbols.swift` files (whether they came
        //     from OutputFileMap or DerivedSources) so their resource-bundle
        //     lookup points at the framework's on-disk wrapper. The generator
        //     emits `Bundle(for: ResourceBundleClass.self)`, which when
        //     recompiled into the bridge dylib resolves to the dylib itself
        //     (no `Assets.car`) — asset lookups silently return nothing (#151).
        if let sources = sourceFiles {
            sourceFiles = Self.applyResourceBundleRewrites(sources: sources, settings: settings)
        }

        // 6. Build compiler flags
        var compilerFlags = buildCompilerFlags(settings: settings)
        let package = await Self.swiftPMPackageProducts(builtProductsDir: builtProductsDir)
        compilerFlags += package.flags

        return BuildContext(
            moduleName: moduleName,
            compilerFlags: compilerFlags,
            projectRoot: projectRoot,
            targetName: targetName,
            frameworkPaths: package.frameworkPaths,
            sourceFiles: sourceFiles
        )
    }

    // MARK: - Private: Compile Capture

    /// The captured compile command for the module: parsed from the build
    /// log, or the persisted capture from an earlier start when this build
    /// was null, or parsed after forcing the module to recompile (a source
    /// touch) when neither exists. Nil when the build system never logs
    /// SwiftDriver invocations (build-with-Bazel).
    private func captureCommand(
        buildLog: String, scheme: String, platform: PreviewPlatform,
        moduleName: String, builtProductsDir: String
    ) async throws -> XcodeCommandCapture.CapturedCommand? {
        let persistURL = persistedCaptureURL(builtProductsDir, moduleName)
        let validity = captureValidity()
        func parseAndPersist(_ log: String) -> XcodeCommandCapture.CapturedCommand? {
            guard
                let captured = XcodeCommandCapture.parse(log: log, moduleName: moduleName)
            else { return nil }
            XcodeCommandCapture.persist(captured, at: persistURL, validity: validity)
            return captured
        }

        if let captured = parseAndPersist(buildLog) {
            return captured
        }
        switch XcodeCommandCapture.loadPersisted(at: persistURL, validity: validity) {
        case let .command(persisted): return persisted
        case .driverless: return nil
        case nil: break
        }

        // No compile line and no valid persisted capture. A null build and a
        // build-with-Bazel project both log nothing here, so force the module
        // to recompile (identity content; the mtime moves for the build and
        // is restored right after so watchers and the working tree stay
        // clean): under XCBuild the forced log carries the driver line.
        let originalDate = try? FileManager.default
            .attributesOfItem(atPath: sourceFile.path)[.modificationDate] as? Date
        try? FileManager.default.setAttributes(
            [.modificationDate: Date()], ofItemAtPath: sourceFile.path
        )
        let forcedLog = try await runBuild(scheme: scheme, platform: platform)
        if let originalDate {
            try? FileManager.default.setAttributes(
                [.modificationDate: originalDate], ofItemAtPath: sourceFile.path
            )
        }
        if let captured = parseAndPersist(forcedLog) {
            return captured
        }
        // Only a log showing Bazel actually drove the build earns the
        // persisted driverless marker; anything else (content-signature
        // no-op rebuilds, variant schemes) falls back for this start and
        // retries the probe next time.
        if !XcodeCommandCapture.logsDriverInvocations(forcedLog),
           forcedLog.contains("bazel")
        {
            XcodeCommandCapture.persist(nil, at: persistURL, validity: validity)
        }
        Log.info(
            "xcode capture: no compile command for \(moduleName); using settings derivation"
        )
        return nil
    }

    private nonisolated func persistedCaptureURL(
        _ builtProductsDir: String, _ moduleName: String
    ) -> URL {
        URL(fileURLWithPath: builtProductsDir)
            .appendingPathComponent("previewsmcp-capture-\(moduleName).json")
    }

    private nonisolated func captureValidity() -> [String: Date] {
        XcodeCommandCapture.validityKeys(projectFile: projectFile, projectRoot: projectRoot)
    }

    /// Assemble the BuildContext from a captured command: normalized captured
    /// flags plus the link-time inputs a compile command cannot carry
    /// (dependency archives from OTHER_LDFLAGS, Xcode-managed package
    /// products, and the target's own C/ObjC objects for bridging-header
    /// symbols).
    private func buildContext(
        from captured: XcodeCommandCapture.CapturedCommand,
        settings: [String: String],
        moduleName: String, targetName: String, builtProductsDir: String,
        platform: PreviewPlatform
    ) async throws -> BuildContext {
        var flags = CompileCommandNormalizer.normalize(
            Self.stripForeignTargetTriple(captured.arguments, platform: platform)
        )

        if let ldFlags = settings["OTHER_LDFLAGS"] {
            let archives = Self.collectDependencyArchives(fromOtherLDFlags: ldFlags)
            flags += Self.archiveLinkFlags(archivePaths: archives, targetName: targetName)
        }
        let package = await Self.swiftPMPackageProducts(builtProductsDir: builtProductsDir)
        flags += package.flags

        // Dependency frameworks built into the products directory (referenced
        // projects, X01): -F/-framework pairs are what the JIT agent resolves
        // to framework binaries to dlopen. The target's own framework is the
        // Tier 2 recompile itself, never loaded.
        var ownNames: Set<String> = [moduleName, targetName]
        for key in ["PRODUCT_NAME", "EXECUTABLE_NAME"] {
            if let value = settings[key] { ownNames.insert(value) }
        }
        if let wrapper = settings["CODESIGNING_FOLDER_PATH"] {
            ownNames.insert(
                URL(fileURLWithPath: wrapper).deletingPathExtension().lastPathComponent
            )
        }
        let dependencyFrameworks = BuildSystemSupport.collectFrameworks(
            binPath: URL(fileURLWithPath: builtProductsDir)
        ).filter { !ownNames.contains($0) }
        if !dependencyFrameworks.isEmpty {
            flags += ["-F", builtProductsDir]
            for framework in dependencyFrameworks {
                flags += ["-framework", framework]
            }
        }

        let wholeModule = captured.arguments.contains { $0 == "-whole-module-optimization" || $0 == "-wmo" }
        let clangObjects = Self.clangObjects(
            settings: settings,
            excludedStems: wholeModule ? [targetName] : [],
            swiftSources: captured.swiftSources
        )
        if !clangObjects.isEmpty {
            flags += await Self.clangObjectLinkFlags(
                objects: clangObjects,
                moduleName: moduleName,
                builtProductsDir: builtProductsDir
            )
        }

        let previewPath = sourceFile.resolvingSymlinksInPath().path
        var sourceFiles = captured.swiftSources
            .map { URL(fileURLWithPath: $0).standardizedFileURL }
            .filter { $0.resolvingSymlinksInPath().path != previewPath }

        // An unreadable SwiftFileList must not silently shrink Tier 2 to the
        // preview file alone; the OutputFileMap enumeration is the fallback
        // source list.
        if sourceFiles.isEmpty,
           let fallback = collectSourceFiles(settings: settings, targetName: targetName)
        {
            sourceFiles = fallback
        }

        // Union Xcode-generated Swift sources from DERIVED_FILE_DIR (asset
        // symbols and friends are generated during the build; a capture from
        // an earlier log may predate them).
        if let derivedFileDir = settings["DERIVED_FILE_DIR"] {
            let generated = Self.collectGeneratedSources(
                derivedFileDir: URL(fileURLWithPath: derivedFileDir)
            )
            let seen = Set(sourceFiles.map(\.path))
            sourceFiles += generated.filter { !seen.contains($0.path) }
        }
        sourceFiles = Self.applyResourceBundleRewrites(sources: sourceFiles, settings: settings)

        return BuildContext(
            moduleName: moduleName,
            compilerFlags: flags,
            projectRoot: projectRoot,
            targetName: targetName,
            frameworkPaths: package.frameworkPaths,
            sourceFiles: sourceFiles.isEmpty ? nil : sourceFiles
        )
    }

    /// Xcode pre-processing for the shared normalizer: a scheme can build a
    /// platform variant the preview environment cannot host (Mac Catalyst
    /// under the macOS agent), and the captured `-target`/`-sdk` would
    /// otherwise win over Compiler's injection. Keep the captured pair only
    /// when the triple matches the preview platform family.
    static func stripForeignTargetTriple(
        _ args: [String], platform: PreviewPlatform
    ) -> [String] {
        guard
            let index = args.firstIndex(of: "-target"), index + 1 < args.count
        else { return args }
        let triple = args[index + 1]
        let compatible =
            switch platform {
            case .macOS: triple.contains("apple-macos")
            case .iOS: triple.contains("simulator")
            }
        guard !compatible else { return args }
        var result = args
        result.removeSubrange(index ... index + 1)
        if let sdkIndex = result.firstIndex(of: "-sdk"), sdkIndex + 1 < result.count {
            result.removeSubrange(sdkIndex ... sdkIndex + 1)
        }
        return result
    }

    /// The target's C/ObjC objects: everything in the objects directory that
    /// is not a Swift compile output. Swift outputs are named after the
    /// captured Swift sources — plus the whole-module master object named
    /// after the target when the capture shows WMO — and over-inclusion is
    /// otherwise safe because archive members link lazily.
    private static func clangObjects(
        settings: [String: String], excludedStems: [String], swiftSources: [String]
    ) -> [String] {
        guard let objectFileDir = settings["OBJECT_FILE_DIR_normal"] else { return [] }
        let objectsDir = URL(fileURLWithPath: objectFileDir).appendingPathComponent(hostArch)
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: objectsDir, includingPropertiesForKeys: nil
            )
        else { return [] }
        var swiftStems = Set(
            swiftSources.map {
                URL(fileURLWithPath: $0).deletingPathExtension().lastPathComponent
            }
        )
        swiftStems.formUnion(excludedStems)
        return entries
            .filter { $0.pathExtension == "o" }
            .filter { !swiftStems.contains($0.deletingPathExtension().lastPathComponent) }
            .map(\.path)
            .sorted()
    }

    /// Archive the target's C/ObjC objects and emit -L/-l for the
    /// JIT link, so bridging-header symbols resolve at runtime (X02's link
    /// half).
    private static func clangObjectLinkFlags(
        objects: [String], moduleName: String, builtProductsDir: String
    ) async -> [String] {
        let cacheDir = (builtProductsDir as NSString)
            .appendingPathComponent(Self.archiveCacheDirName)
        try? FileManager.default.createDirectory(
            atPath: cacheDir, withIntermediateDirectories: true
        )
        let libName = "\(moduleName)PreviewClang"
        let archivePath = (cacheDir as NSString).appendingPathComponent("lib\(libName).a")
        try? FileManager.default.removeItem(atPath: archivePath)
        let result = try? await runAsync(
            "/usr/bin/ar", arguments: ["rcs", archivePath] + objects
        )
        guard result?.exitCode == 0 else { return [] }
        return ["-L", cacheDir, "-l\(libName)"]
    }

    // MARK: - Private: Scheme Discovery

    struct ProjectInfo {
        let schemes: [String]
        init(schemes: [String]) {
            self.schemes = schemes
        }
    }

    private func listSchemes() async throws -> ProjectInfo {
        let output = try await runXcodebuild(
            xcodebuildFlag, projectFile.path, "-list", "-json"
        )
        guard let data = output.data(using: .utf8) else {
            throw BuildSystemError.missingArtifacts(
                "Could not parse xcodebuild -list output"
            )
        }
        return try JSONDecoder().decode(ProjectInfo.self, from: data)
    }

    func pickScheme(from info: ProjectInfo) throws -> String {
        let schemes = info.schemes
        guard !schemes.isEmpty else {
            throw BuildSystemError.targetNotFound(
                sourceFile: sourceFile.lastPathComponent,
                project: projectFile.lastPathComponent
            )
        }

        // 1. Explicit scheme from caller wins, if it's actually in the list.
        if let requested = requestedScheme {
            if schemes.contains(requested) {
                return requested
            }
            throw BuildSystemError.unknownScheme(
                requested: requested,
                candidates: schemes
            )
        }

        // 2. Exactly one scheme: unambiguous.
        if schemes.count == 1 { return schemes[0] }

        // 3. A scheme named after the ownership-confirmed target beats the
        //    path heuristic below.
        if let confirmedTarget, schemes.contains(confirmedTarget) {
            return confirmedTarget
        }

        // 4. Multiple schemes: try to match the target directory containing the
        //    source file. This is a heuristic and only fires when a scheme name
        //    appears as a directory component on the source file path.
        let pathComponents = Set(sourceFile.pathComponents)
        if let match = schemes.first(where: { pathComponents.contains($0) }) {
            return match
        }

        // 5. Give up and ask the caller to disambiguate.
        throw BuildSystemError.ambiguousTarget(
            sourceFile: sourceFile.lastPathComponent,
            candidates: schemes
        )
    }

    // MARK: - Private: Build Settings

    private func getBuildSettings(
        scheme: String, platform: PreviewPlatform
    ) async throws -> [String: String] {
        let destination = destinationString(for: platform)
        let output = try await runXcodebuild(
            xcodebuildFlag, projectFile.path,
            "-scheme", scheme,
            "-showBuildSettings",
            "-destination", destination
        )
        return Self.parseBuildSettings(output, target: confirmedTarget)
    }

    /// Parse build settings from xcodebuild output. Parses the named target's
    /// section when given (a scheme can build several targets and the first is
    /// not necessarily the owner); otherwise, or when the named target has no
    /// section, the first target's settings.
    static func parseBuildSettings(_ output: String, target: String? = nil) -> [String: String] {
        if let target {
            let settings = parseFirstSettingsBlock(
                output, startingAt: "Build settings for action build and target \(target):"
            )
            if !settings.isEmpty { return settings }
        }
        return parseFirstSettingsBlock(output, startingAt: "Build settings for")
    }

    private static func parseFirstSettingsBlock(
        _ output: String, startingAt header: String
    ) -> [String: String] {
        var settings: [String: String] = [:]
        var foundFirstTarget = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if !foundFirstTarget {
                if trimmed.hasPrefix(header) { foundFirstTarget = true }
                continue
            }
            if trimmed.hasPrefix("Build settings for") { break }
            guard let equalsRange = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex ..< equalsRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[equalsRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            settings[key] = value
        }
        return settings
    }

    // MARK: - Private: Build

    /// Runs the build and returns the full log — the compile capture reads
    /// the swiftc invocation out of it, so -quiet must stay off. No
    /// -configuration override: the scheme's own build configuration (which
    /// may be custom, X01) selects the xcconfig contents the capture must
    /// reflect.
    @discardableResult
    private func runBuild(scheme: String, platform: PreviewPlatform) async throws -> String {
        let destination = destinationString(for: platform)
        return try await runXcodebuild(
            "build",
            xcodebuildFlag, projectFile.path,
            "-scheme", scheme,
            "-destination", destination
        )
    }

    // MARK: - Private: Source Files (Tier 2)

    /// Collect source files from the OutputFileMap.json produced by xcodebuild.
    /// Returns nil if the file doesn't exist (falls back to Tier 1).
    func collectSourceFiles(settings: [String: String], targetName: String) -> [URL]? {
        // OutputFileMap lives at <OBJECT_FILE_DIR_normal>/arm64/<Target>-OutputFileMap.json
        guard let objectFileDir = settings["OBJECT_FILE_DIR_normal"] else { return nil }

        let outputFileMapPath = URL(fileURLWithPath: objectFileDir)
            .appendingPathComponent("arm64")
            .appendingPathComponent("\(targetName)-OutputFileMap.json")

        guard let data = try? Data(contentsOf: outputFileMapPath),
              let map = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        // Keys are absolute source file paths; "" is module-level metadata (skip it)
        var sourceFiles: [URL] = []
        for key in map.keys {
            guard !key.isEmpty, key.hasSuffix(".swift") else { continue }
            let url = URL(fileURLWithPath: key).standardizedFileURL
            if url.path != sourceFile.path {
                sourceFiles.append(url)
            }
        }

        return sourceFiles.isEmpty ? nil : sourceFiles
    }

    /// Collect Xcode-generated Swift sources that the Xcode driver would
    /// normally feed to swiftc. Xcode writes these to
    /// `<DERIVED_FILE_DIR>/DerivedSources/` — `GeneratedAssetSymbols.swift`
    /// (asset catalog symbols), `GeneratedStringSymbols.swift` (string
    /// catalogs), `GeneratedPlistSymbols.swift`, and similar. No filename
    /// whitelist — Xcode's generator set changes across releases.
    nonisolated static func collectGeneratedSources(derivedFileDir: URL) -> [URL] {
        let derivedSources = derivedFileDir.appendingPathComponent("DerivedSources")
        return BuildSystemSupport.collectGeneratedSources(in: derivedSources)
    }

    /// Apply `rewriteResourceBundle` to every source file when the build
    /// settings name a resource wrapper that exists on disk. Returns `sources`
    /// unchanged if `CODESIGNING_FOLDER_PATH` is missing, points at a
    /// non-existent path, or `DERIVED_FILE_DIR` is missing — in those cases
    /// the rewrite would either crash with a nil-bundle path or silently
    /// reintroduce the bug, so it's safer to fall back to the original
    /// behavior and log a warning.
    nonisolated static func applyResourceBundleRewrites(
        sources: [URL],
        settings: [String: String]
    ) -> [URL] {
        guard let wrapperPath = settings["CODESIGNING_FOLDER_PATH"] else {
            return sources
        }
        guard FileManager.default.fileExists(atPath: wrapperPath) else {
            Log.warn(
                "CODESIGNING_FOLDER_PATH=\(wrapperPath) does not exist; "
                    + "skipping resource-bundle rewrite. Asset lookups in "
                    + "the bridge dylib may return nothing."
            )
            return sources
        }
        guard let derivedFileDir = settings["DERIVED_FILE_DIR"] else {
            return sources
        }
        let rewriteDir = URL(fileURLWithPath: derivedFileDir)
            .appendingPathComponent("PreviewsMCPRewrites")
        return sources.map { source in
            rewriteResourceBundle(
                source: source, wrapperPath: wrapperPath, rewriteDir: rewriteDir
            )
        }
    }

    /// If `source` matches the `Generated*Symbols.swift` resource-bundle
    /// preamble, write a rewritten copy to `rewriteDir` and return its URL;
    /// otherwise return `source` unchanged.
    nonisolated static func rewriteResourceBundle(
        source: URL,
        wrapperPath: String,
        rewriteDir: URL
    ) -> URL {
        guard source.lastPathComponent.hasPrefix("Generated"),
              source.lastPathComponent.hasSuffix("Symbols.swift"),
              let original = try? String(contentsOf: source, encoding: .utf8)
        else {
            return source
        }
        let needle = """
        #if SWIFT_PACKAGE
        private let resourceBundle = Foundation.Bundle.module
        #else
        private class ResourceBundleClass {}
        private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
        #endif
        """
        guard original.contains(needle) else {
            return source
        }
        let escaped = wrapperPath.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        let replacement = """
        #if SWIFT_PACKAGE
        private let resourceBundle = Foundation.Bundle.module
        #else
        // PreviewsMCP rewrite (#151): the recompiled bridge dylib has no
        // resource bundle of its own; point at the framework on disk.
        private let resourceBundle = Foundation.Bundle(path: "\(escaped)") ?? Foundation.Bundle.main
        #endif
        """
        let rewritten = original.replacingOccurrences(of: needle, with: replacement)
        do {
            try FileManager.default.createDirectory(
                at: rewriteDir, withIntermediateDirectories: true
            )
            let dest = rewriteDir.appendingPathComponent(source.lastPathComponent)
            try rewritten.write(to: dest, atomically: true, encoding: .utf8)
            Log.info(
                "rewroteResourceBundle: \(source.lastPathComponent) -> \(dest.path) "
                    + "(bundle=\(wrapperPath))"
            )
            return dest
        } catch {
            Log.warn(
                "rewriteResourceBundle failed for \(source.lastPathComponent): \(error). "
                    + "Falling back to original; asset lookups may return nothing."
            )
            return source
        }
    }

    // MARK: - Private: Compiler Flags

    private func buildCompilerFlags(settings: [String: String]) -> [String] {
        var flags: [String] = []
        var seenPaths: Set<String> = []

        // Framework search path for the target's own framework
        if let builtProductsDir = settings["BUILT_PRODUCTS_DIR"] {
            flags += ["-F", builtProductsDir]
            seenPaths.insert(builtProductsDir)
        }

        // Additional framework search paths for dependencies
        if let searchPaths = settings["FRAMEWORK_SEARCH_PATHS"] {
            for path in Self.parseSearchPaths(searchPaths)
                where seenPaths.insert(path).inserted
            {
                flags += ["-F", path]
            }
        }

        // Dependency module search paths from OTHER_SWIFT_FLAGS. rules_xcodeproj
        // (Build-with-Bazel) puts dependency swiftmodules and objc module maps
        // under bazel-out and exposes them here, not via the standard search
        // path settings. Reuse those flags so the overlay recompile resolves
        // `import SwiftLib` / `import ObjCLib`.
        if let otherSwiftFlags = settings["OTHER_SWIFT_FLAGS"] {
            flags += Self.extractDependencyImportFlags(fromOtherSwiftFlags: otherSwiftFlags)
        }

        // Dependency static archives from OTHER_LDFLAGS. The JIT resolves the
        // overlay's cross-module symbols (e.g. SwiftLib/ObjCLib functions used
        // by the preview) by linking these. Under rules_xcodeproj the linker
        // inputs come via an `@<link.params>` response file; the target's own
        // object is a `.lto.o`, so collecting the `.a` entries yields only deps.
        if let ldFlags = settings["OTHER_LDFLAGS"] {
            let archives = Self.collectDependencyArchives(fromOtherLDFlags: ldFlags)
            flags += Self.archiveLinkFlags(archivePaths: archives, targetName: settings["TARGET_NAME"])
        }

        return flags
    }

    /// Split a build-setting flag string into non-empty whitespace-separated tokens.
    static func tokenizeFlags(_ value: String) -> [String] {
        value
            .split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" })
            .map(String.init)
            .filter { !$0.isEmpty }
    }

    /// Collect dependency static-archive paths referenced by `OTHER_LDFLAGS`,
    /// following an `@<file>` linker response file when present. Archives may
    /// appear bare or behind a linker directive (`-force_load <path>`,
    /// `-Wl,-force_load,<path>`), so each token is split on whitespace and any
    /// `-Wl,`-style comma prefix is stripped before the `.a` check.
    static func collectDependencyArchives(fromOtherLDFlags value: String) -> [String] {
        var archives: [String] = []
        func appendArchive(_ token: String) {
            let path = token.contains(",") ? String(token.split(separator: ",").last ?? "") : token
            if path.hasSuffix(".a"), FileManager.default.fileExists(atPath: path) {
                archives.append(path)
            }
        }
        for token in Self.tokenizeFlags(value) {
            if token.hasPrefix("@") {
                let file = String(token.dropFirst())
                guard let content = try? String(contentsOfFile: file, encoding: .utf8) else {
                    continue
                }
                Self.tokenizeFlags(content).forEach(appendArchive)
            } else {
                appendArchive(token)
            }
        }
        return archives
    }

    /// Turn dependency archive paths into deduped `-L <dir>` / `-l<name>` pairs
    /// (which `PreviewSession.dependencyArchives` resolves back to `lib<name>.a`),
    /// excluding the target's own `lib<TargetName>.a` archive.
    static func archiveLinkFlags(archivePaths: [String], targetName: String?) -> [String] {
        let ownArchive = targetName.map { "lib\($0).a" }
        var flags: [String] = []
        var seen = Set<String>()
        for path in archivePaths {
            let name = (path as NSString).lastPathComponent
            guard name.hasPrefix("lib"), name.hasSuffix(".a") else { continue }
            if let ownArchive, name == ownArchive { continue }
            let dir = (path as NSString).deletingLastPathComponent
            let lib = String(name.dropFirst(3).dropLast(2))
            if seen.insert("L:" + dir).inserted { flags += ["-L", dir] }
            if seen.insert("l:" + lib).inserted { flags += ["-l" + lib] }
        }
        return flags
    }

    /// Extract dependency import flags from `OTHER_SWIFT_FLAGS`, keeping only the
    /// search-path flags an overlay recompile needs (`-I`, `-F`, and the clang
    /// `-Xcc` module-map / include / working-directory pairs). Compile-action
    /// flags like `-emit-const-values-path`, `-static`, and `-enable-testing`
    /// are dropped.
    static func extractDependencyImportFlags(fromOtherSwiftFlags flags: String) -> [String] {
        let tokens = tokenizeFlags(flags)
        let clangValueFlags: Set = ["-iquote", "-isystem", "-working-directory", "-I"]
        var result: [String] = []
        var seen = Set<String>()
        func add(_ items: [String], key: String) {
            if seen.insert(key).inserted { result += items }
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t == "-Xcc", i + 1 < tokens.count {
                let arg = tokens[i + 1]
                if arg.hasPrefix("-fmodule-map-file=") || (arg.hasPrefix("-I") && arg.count > 2) {
                    add(["-Xcc", arg], key: "xcc:" + arg)
                    i += 2
                    continue
                }
                if clangValueFlags.contains(arg), i + 3 < tokens.count, tokens[i + 2] == "-Xcc" {
                    let value = tokens[i + 3]
                    add(["-Xcc", arg, "-Xcc", value], key: "xcc:\(arg):\(value)")
                    i += 4
                    continue
                }
                // Most dropped -Xcc args are compile-only flags (-O0, -DDEBUG)
                // and are expected. Warn only when an import-related flag arrives
                // in an unhandled shape, so format drift is observable.
                if clangValueFlags.contains(arg)
                    || ["-iquote", "-isystem", "-working-directory"].contains(where: arg.hasPrefix)
                {
                    Log.warn("extractDependencyImportFlags: dropped import flag -Xcc \(arg)")
                }
                i += 2
                continue
            }
            if t.hasPrefix("-I"), t.count > 2 {
                add(["-I", String(t.dropFirst(2))], key: "I:" + t)
            } else if t.hasPrefix("-F"), t.count > 2 {
                add(["-F", String(t.dropFirst(2))], key: "F:" + t)
            }
            i += 1
        }
        return result
    }

    /// Parse space-separated paths from xcodebuild, filtering out $(inherited) and quotes.
    static func parseSearchPaths(_ value: String) -> [String] {
        value.components(separatedBy: " ")
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
            .filter { !$0.isEmpty && $0 != "$(inherited)" }
    }

    // MARK: - Private: Platform

    private func destinationString(for platform: PreviewPlatform) -> String {
        switch platform {
        case .macOS:
            "platform=macOS"
        case .iOS:
            "generic/platform=iOS Simulator"
        }
    }

    // MARK: - Private: Process Execution

    @discardableResult
    private func runXcodebuild(_ args: String...) async throws -> String {
        try await runXcodebuild(args: args)
    }

    @discardableResult
    private func runXcodebuild(args: [String]) async throws -> String {
        let fullArgs = ["xcodebuild"] + args
        let output = try await runAsync(
            "/usr/bin/env", arguments: fullArgs,
            workingDirectory: projectRoot
        )
        guard output.exitCode == 0 else {
            throw BuildSystemError.buildFailed(
                stderr: output.stderr.isEmpty ? output.stdout : output.stderr,
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }
}

// MARK: - Xcode-managed SwiftPM package products

extension XcodeBuildSystem {
    /// Xcode-managed SwiftPM packages land in `BUILT_PRODUCTS_DIR` as a bare
    /// `<Module>.swiftmodule` plus a loose, universal `<Module>.o` (no `.a`, and no
    /// `-l`/`-framework` surface in the build settings). Turn each into the inputs the
    /// JIT pipeline consumes:
    ///   - `-I <dir>` so the overlay recompile resolves `import <Module>`.
    ///   - thin each `.o` to the host arch and wrap it in a single-member
    ///     `lib<Module>.a`, emitted as `-L`/`-l`. One archive per object means the
    ///     linker pulls only the modules the preview actually imports.
    ///   - the canonical path of each system framework the object autolinks (e.g.
    ///     DeviceCheck, read from `LC_LINKER_OPTION`), returned separately so the agent
    ///     `dlopen`s it from the dyld shared cache without the name reaching swiftc.
    /// Inert when `BUILT_PRODUCTS_DIR` holds no loose objects (the rules_xcodeproj and
    /// framework-only cases), so it only affects the native SwiftPM-package path.
    static func swiftPMPackageProducts(
        builtProductsDir: String
    ) async -> (flags: [String], frameworkPaths: [URL]) {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: builtProductsDir) else {
            return ([], [])
        }
        let objects = entries.filter { $0.hasSuffix(".o") }.sorted()
        guard !objects.isEmpty else { return ([], []) }

        let cacheDir = (builtProductsDir as NSString)
            .appendingPathComponent(Self.archiveCacheDirName)
        try? fm.createDirectory(atPath: cacheDir, withIntermediateDirectories: true)

        // Each object's archive + autolink work is independent, so process them
        // concurrently; a large package closure is the case #281 targets.
        let archived = await withTaskGroup(of: (base: String, frameworks: Set<String>).self) {
            group in
            for object in objects {
                group.addTask {
                    await Self.archivePackageObject(
                        object: object, builtProductsDir: builtProductsDir, cacheDir: cacheDir
                    )
                }
            }
            var results: [(base: String, frameworks: Set<String>)] = []
            for await result in group {
                results.append(result)
            }
            return results.sorted { $0.base < $1.base }
        }

        var flags = ["-I", builtProductsDir]
        var frameworks = Set<String>()
        for entry in archived {
            flags += ["-L", cacheDir, "-l\(entry.base)"]
            frameworks.formUnion(entry.frameworks)
        }
        let frameworkPaths = frameworks.sorted().map {
            URL(fileURLWithPath: "/System/Library/Frameworks/\($0).framework/\($0)")
        }
        return (flags, frameworkPaths)
    }

    /// Thin one package object to the host arch, wrap it in a single-member
    /// `lib<base>.a` under `cacheDir`, and return its autolinked frameworks.
    private static func archivePackageObject(
        object: String, builtProductsDir: String, cacheDir: String
    ) async -> (base: String, frameworks: Set<String>) {
        let fm = FileManager.default
        let objectPath = (builtProductsDir as NSString).appendingPathComponent(object)
        let base = String(object.dropLast(2))
        async let frameworks = autolinkFrameworks(objectPath: objectPath)

        let thin = (cacheDir as NSString).appendingPathComponent("\(base).o")
        _ = try? await runAsync(
            "/usr/bin/lipo", arguments: ["-thin", hostArch, objectPath, "-output", thin],
            discardStderr: true
        )
        let linkObject = fm.fileExists(atPath: thin) ? thin : objectPath
        let archive = (cacheDir as NSString).appendingPathComponent("lib\(base).a")
        try? fm.removeItem(atPath: archive)
        _ = try? await runAsync(
            "/usr/bin/ar", arguments: ["rcs", archive, linkObject], discardStderr: true
        )
        return (base, await frameworks)
    }

    /// Archives PreviewsMCP creates beside the build products for the JIT link.
    static let archiveCacheDirName = "previewsmcp-package-archives"

    /// The arch the JIT agent runs as, used to thin universal package objects.
    static var hostArch: String {
        #if arch(arm64)
            return "arm64"
        #else
            return "x86_64"
        #endif
    }

    /// Read the `-framework <name>` autolink directives Swift bakes into an object's
    /// `LC_LINKER_OPTION` load commands. These name the system frameworks the object
    /// depends on (e.g. DeviceCheck) that have no presence in the build settings.
    static func autolinkFrameworks(objectPath: String) async -> Set<String> {
        guard let output = try? await runAsync("/usr/bin/otool", arguments: ["-l", objectPath]) else {
            return []
        }
        let lines = output.stdout.split(separator: "\n")
        var names = Set<String>()
        for (index, line) in lines.enumerated()
            where line.contains("string #1 -framework") && index + 1 < lines.count
        {
            if let range = lines[index + 1].range(of: "string #2 ") {
                names.insert(
                    String(lines[index + 1][range.upperBound...])
                        .trimmingCharacters(in: .whitespaces)
                )
            }
        }
        return names
    }
}

// MARK: - ProjectInfo Decodable

extension XcodeBuildSystem.ProjectInfo: Decodable {
    private enum CodingKeys: String, CodingKey {
        case project
        case workspace
    }

    private struct Details: Decodable {
        let schemes: [String]
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.project) {
            schemes = try container.decode(Details.self, forKey: .project).schemes
        } else if container.contains(.workspace) {
            schemes = try container.decode(Details.self, forKey: .workspace).schemes
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                    "Expected 'project' or 'workspace' key in xcodebuild -list JSON"
                )
            )
        }
    }
}

// MARK: - Ownership

extension XcodeBuildSystem {
    /// Confirm membership from the project file(s) themselves, before any
    /// build: classic targets via PBXBuildFile references, Xcode 16+
    /// synchronized groups via folder containment minus exception sets. A
    /// workspace checks each referenced project.
    static func confirmOwnership(
        projectRoot: URL, projectFile: URL, sourceFile: URL, scheme: String?
    ) async -> OwnershipVerdict {
        let projects =
            projectFile.pathExtension == "xcworkspace"
                ? XcodeProjectMembership.projects(inWorkspace: projectFile)
                : [projectFile]
        guard !projects.isEmpty else {
            // A packages-only workspace (no .xcodeproj) cannot own the
            // compile in this model — a definitive answer, so the walk may
            // continue to farther roots.
            return .notMember(
                reason: "\(projectFile.lastPathComponent) references no .xcodeproj"
            )
        }

        var memberships: [XcodeProjectMembership.TargetMembership] = []
        var unparseable: [String] = []
        for project in projects {
            do {
                memberships += try XcodeProjectMembership.targets(
                    compiling: sourceFile, inProject: project
                )
            } catch {
                unparseable.append(project.lastPathComponent)
            }
        }

        guard !memberships.isEmpty else {
            if !unparseable.isEmpty {
                return .indeterminate(
                    reason: "could not parse \(unparseable.joined(separator: ", "))"
                )
            }
            var reason =
                "no target in \(projectFile.lastPathComponent) compiles \(sourceFile.lastPathComponent)"
            if generatedProjectManifest(in: projectFile.deletingLastPathComponent()) != nil {
                reason += "; the project may be stale — run `xcodegen generate`"
            }
            return .notMember(reason: reason)
        }

        let nonTest = memberships.filter {
            $0.productType?.localizedCaseInsensitiveContains("test") != true
        }
        let candidates = nonTest.isEmpty ? memberships : nonTest
        let names = candidates.map(\.targetName)
        let chosen: String?
        if names.count == 1 {
            chosen = names[0]
        } else if let scheme, names.contains(scheme) {
            chosen = scheme
        } else if scheme != nil {
            // The scheme parameter names a scheme, not a target; when it
            // matches no target name, ownership is still confirmed and the
            // requested scheme resolves the ambiguity at build time
            // (pickScheme honors it, settings fall to that scheme's first
            // target).
            chosen = nil
        } else {
            return .indeterminate(
                reason:
                "multiple targets compile \(sourceFile.lastPathComponent): \(names.joined(separator: ", ")). Pass the scheme parameter to pick one"
            )
        }
        guard await isXcodebuildAvailable() else {
            return .indeterminate(
                reason:
                "\(projectFile.lastPathComponent) owns \(sourceFile.lastPathComponent) but xcodebuild is unavailable (install full Xcode)"
            )
        }
        return .confirmed(
            Ownership(
                kind: .xcode, projectRoot: projectRoot,
                targetName: chosen, projectFile: projectFile
            )
        )
    }

    private static func isXcodebuildAvailable() async -> Bool {
        ((try? await Toolchain.xcodebuildPath()) ?? nil) != nil
    }

    /// The XcodeGen manifest in the given directory, if any.
    static func generatedProjectManifest(in directory: URL) -> URL? {
        for manifest in ["project.yml", "project.yaml"] {
            let manifestURL = directory.appendingPathComponent(manifest)
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                return manifestURL
            }
        }
        return nil
    }
}

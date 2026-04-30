import Foundation

/// Xcode build system integration for .xcodeproj and .xcworkspace projects.
public actor XcodeBuildSystem: BuildSystem {
    public nonisolated let projectRoot: URL
    private let sourceFile: URL
    private let projectFile: URL
    private let requestedScheme: String?

    /// The xcodebuild flag for referencing the project or workspace.
    private var xcodebuildFlag: String {
        projectFile.pathExtension == "xcworkspace" ? "-workspace" : "-project"
    }

    public init(
        projectRoot: URL,
        sourceFile: URL,
        projectFile: URL,
        requestedScheme: String? = nil
    ) {
        self.projectRoot = projectRoot
        self.sourceFile = sourceFile.standardizedFileURL
        self.projectFile = projectFile
        self.requestedScheme = requestedScheme
    }

    // MARK: - Detection

    public static func detect(for sourceFile: URL) async throws -> XcodeBuildSystem? {
        try await detect(for: sourceFile, scheme: nil)
    }

    public static func detect(
        for sourceFile: URL,
        scheme: String?
    ) async throws -> XcodeBuildSystem? {
        var dir = sourceFile.deletingLastPathComponent().standardizedFileURL
        let root = URL(fileURLWithPath: "/")

        while dir.path != root.path {
            if let projectFile = findXcodeProject(in: dir) {
                guard await isXcodebuildAvailable() else { return nil }
                return XcodeBuildSystem(
                    projectRoot: dir,
                    sourceFile: sourceFile.standardizedFileURL,
                    projectFile: projectFile,
                    requestedScheme: scheme)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    /// Find a .xcworkspace or .xcodeproj in the given directory.
    /// Prefers a .xcworkspace whose name matches a colocated .xcodeproj (standard Xcode convention),
    /// then falls back to any workspace, then any project.
    static func findXcodeProject(in directory: URL) -> URL? {
        guard
            let contents = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
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

    private static func isXcodebuildAvailable() async -> Bool {
        do {
            let output = try await runAsync(
                "/usr/bin/xcrun", arguments: ["--find", "xcodebuild"], discardStderr: true)
            return output.exitCode == 0
        } catch {
            return false
        }
    }

    // MARK: - Build

    public func build(platform: PreviewPlatform) async throws -> BuildContext {
        // 1. List schemes and pick one
        let projectInfo = try await listSchemes()
        let scheme = try pickScheme(from: projectInfo)

        // 2. Build the project (must happen before getBuildSettings so DerivedData is populated)
        try await runBuild(scheme: scheme, platform: platform)

        // 3. Get build settings (post-build so all paths are valid)
        let settings = try await getBuildSettings(scheme: scheme, platform: platform)

        let moduleName =
            settings["PRODUCT_MODULE_NAME"] ?? settings["TARGET_NAME"] ?? scheme
        let targetName = settings["TARGET_NAME"] ?? scheme

        // 4. Verify build products exist
        guard let builtProductsDir = settings["BUILT_PRODUCTS_DIR"] else {
            throw BuildSystemError.missingArtifacts(
                "BUILT_PRODUCTS_DIR not found in build settings for scheme \(scheme)")
        }

        guard FileManager.default.fileExists(atPath: builtProductsDir) else {
            throw BuildSystemError.missingArtifacts(
                "Build products directory not found at \(builtProductsDir)")
        }

        // 5. Collect source files for Tier 2 (from OutputFileMap.json)
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
        let compilerFlags = buildCompilerFlags(settings: settings)

        return BuildContext(
            moduleName: moduleName,
            compilerFlags: compilerFlags,
            projectRoot: projectRoot,
            targetName: targetName,
            sourceFiles: sourceFiles
        )
    }

    // MARK: - Private: Scheme Discovery

    struct ProjectInfo {
        let schemes: [String]
        init(schemes: [String]) { self.schemes = schemes }
    }

    private func listSchemes() async throws -> ProjectInfo {
        let output = try await runXcodebuild(
            xcodebuildFlag, projectFile.path, "-list", "-json")
        guard let data = output.data(using: .utf8) else {
            throw BuildSystemError.missingArtifacts(
                "Could not parse xcodebuild -list output")
        }
        return try JSONDecoder().decode(ProjectInfo.self, from: data)
    }

    func pickScheme(from info: ProjectInfo) throws -> String {
        let schemes = info.schemes
        guard !schemes.isEmpty else {
            throw BuildSystemError.targetNotFound(
                sourceFile: sourceFile.lastPathComponent,
                project: projectFile.lastPathComponent)
        }

        // 1. Explicit scheme from caller wins, if it's actually in the list.
        if let requested = requestedScheme {
            if schemes.contains(requested) {
                return requested
            }
            throw BuildSystemError.unknownScheme(
                requested: requested,
                candidates: schemes)
        }

        // 2. Exactly one scheme: unambiguous.
        if schemes.count == 1 { return schemes[0] }

        // 3. Multiple schemes: try to match the target directory containing the
        //    source file. This is a heuristic and only fires when a scheme name
        //    appears as a directory component on the source file path.
        let pathComponents = Set(sourceFile.pathComponents)
        if let match = schemes.first(where: { pathComponents.contains($0) }) {
            return match
        }

        // 4. Give up and ask the caller to disambiguate.
        throw BuildSystemError.ambiguousTarget(
            sourceFile: sourceFile.lastPathComponent,
            candidates: schemes)
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
            "-destination", destination)
        return Self.parseBuildSettings(output)
    }

    /// Parse build settings from xcodebuild output.
    /// Only parses the first target's settings (stops at the next "Build settings for" header).
    static func parseBuildSettings(_ output: String) -> [String: String] {
        var settings: [String: String] = [:]
        var foundFirstTarget = false
        for line in output.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("Build settings for") {
                if foundFirstTarget { break }
                foundFirstTarget = true
                continue
            }
            guard let equalsRange = trimmed.range(of: " = ") else { continue }
            let key = String(trimmed[trimmed.startIndex..<equalsRange.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            let value = String(trimmed[equalsRange.upperBound...])
                .trimmingCharacters(in: .whitespaces)
            settings[key] = value
        }
        return settings
    }

    // MARK: - Private: Build

    private func runBuild(scheme: String, platform: PreviewPlatform) async throws {
        let destination = destinationString(for: platform)
        try await runXcodebuild(
            "build",
            xcodebuildFlag, projectFile.path,
            "-scheme", scheme,
            "-configuration", "Debug",
            "-destination", destination,
            "-quiet")
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
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: derivedSources,
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
                    + "the bridge dylib may return nothing.")
            return sources
        }
        guard let derivedFileDir = settings["DERIVED_FILE_DIR"] else {
            return sources
        }
        let rewriteDir = URL(fileURLWithPath: derivedFileDir)
            .appendingPathComponent("PreviewsMCPRewrites")
        return sources.map { source in
            rewriteResourceBundle(
                source: source, wrapperPath: wrapperPath, rewriteDir: rewriteDir)
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
                at: rewriteDir, withIntermediateDirectories: true)
            let dest = rewriteDir.appendingPathComponent(source.lastPathComponent)
            try rewritten.write(to: dest, atomically: true, encoding: .utf8)
            Log.info(
                "rewroteResourceBundle: \(source.lastPathComponent) -> \(dest.path) "
                    + "(bundle=\(wrapperPath))")
            return dest
        } catch {
            Log.warn(
                "rewriteResourceBundle failed for \(source.lastPathComponent): \(error). "
                    + "Falling back to original; asset lookups may return nothing.")
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
            where seenPaths.insert(path).inserted {
                flags += ["-F", path]
            }
        }

        return flags
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
            return "platform=macOS"
        case .iOS:
            return "generic/platform=iOS Simulator"
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
            workingDirectory: projectRoot)
        guard output.exitCode == 0 else {
            throw BuildSystemError.buildFailed(
                stderr: output.stderr.isEmpty ? output.stdout : output.stderr,
                exitCode: output.exitCode)
        }
        return output.stdout
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
            self.schemes = try container.decode(Details.self, forKey: .project).schemes
        } else if container.contains(.workspace) {
            self.schemes = try container.decode(Details.self, forKey: .workspace).schemes
        } else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription:
                        "Expected 'project' or 'workspace' key in xcodebuild -list JSON"
                ))
        }
    }
}

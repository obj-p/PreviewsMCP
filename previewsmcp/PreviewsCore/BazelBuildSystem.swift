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
        var compilerFlags = try await findCompilerFlags(
            target: target, moduleName: moduleName, platform: platform)

        // 4b. Add dependency module search paths (swift_library deps and
        //     objc_library module maps) from the target's SwiftCompile action,
        //     so the bridge's `import <Dep>` resolves.
        compilerFlags += try await findDependencyModuleFlags(
            target: target, platform: platform)

        // 4c. Add dependency archive link flags (`-L`/`-l`) for the target's
        //     static-library deps, so the preview JIT link resolves their
        //     cross-target symbols (`findDependencyModuleFlags` only covers the
        //     compile-time module search).
        compilerFlags += try await findDependencyArchiveFlags(
            target: target, platform: platform)

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
        try BuildSystemSupport.verifySwiftModule(named: moduleName, in: moduleDir) {
            BuildSystemError.missingArtifacts(
                "Expected \(moduleName).swiftmodule in bazel-bin output for \(target)")
        }

        return ["-I", moduleDir.path]
    }

    /// Resolve a Bazel `cquery`/`aquery` output path (relative to the execroot,
    /// or already absolute) to an absolute URL.
    private func resolveExecrootPath(_ path: String) -> URL {
        path.hasPrefix("/")
            ? URL(fileURLWithPath: path)
            : projectRoot.appendingPathComponent(path).standardizedFileURL
    }

    /// Extract dependency module-search flags from the target's `SwiftCompile`
    /// action, so the bridge compile can import the target's dependency modules
    /// (`swift_library` deps via `-I`, `objc_library` modules via
    /// `-Xcc -fmodule-map-file=`). The target's own `-I` is added by
    /// `findCompilerFlags`; this fills in everything its `import`s need.
    ///
    /// Reuses Bazel's own flags rather than reconstructing them per dependency,
    /// because objc module maps live at non-obvious paths
    /// (`<pkg>/<name>_modulemap/_/module.modulemap`) that are not in
    /// `cquery --output=files`.
    private func findDependencyModuleFlags(
        target: String, platform: PreviewPlatform
    ) async throws -> [String] {
        var args = ["bazel", "aquery", "mnemonic(\"SwiftCompile\", \(target))"]
        args += platformFlags(for: platform)
        let output = (try? await runBazel(args, discardStderr: true)) ?? ""

        func resolve(_ path: String) -> String { resolveExecrootPath(path).path }

        let tokens =
            output
            .split(whereSeparator: { $0 == "\n" || $0 == " " || $0 == "\t" })
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \t\\'\"")) }
            .filter { !$0.isEmpty }

        var flags: [String] = []
        var seen = Set<String>()
        func add(_ items: [String], key: String) {
            if seen.insert(key).inserted { flags += items }
        }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            if t.hasPrefix("-I"), t.count > 2 {
                let p = resolve(String(t.dropFirst(2)))
                add(["-I", p], key: "I:" + p)
            } else if t.hasPrefix("-F"), t.count > 2 {
                let p = resolve(String(t.dropFirst(2)))
                add(["-F", p], key: "F:" + p)
            } else if t == "-Xcc", i + 1 < tokens.count {
                let next = tokens[i + 1]
                if next.hasPrefix("-fmodule-map-file=") {
                    let p = resolve(String(next.dropFirst("-fmodule-map-file=".count)))
                    add(["-Xcc", "-fmodule-map-file=\(p)"], key: "mmap:" + p)
                    i += 1
                } else if next.hasPrefix("-I"), next.count > 2 {
                    let p = resolve(String(next.dropFirst(2)))
                    add(["-Xcc", "-I\(p)"], key: "XccI:" + p)
                    i += 1
                }
            }
            i += 1
        }
        return flags
    }

    /// Extract `-L <dir>` / `-l<name>` link flags for the target's dependency
    /// static archives (`libSwiftLib.a`, `libObjCLib.a`), so the preview JIT
    /// link resolves their cross-target symbols.
    ///
    /// Building `target` alone materializes its dependency swiftmodules but not
    /// their static archives (a `swift_library` build has no link step), so this
    /// first builds the dependency library targets to put their `.a` on disk.
    ///
    /// `deps(<target>)` also returns two kinds of archives that must NOT be
    /// linked, filtered here:
    ///   * Build tooling in the exec configuration (see `isExecConfigPath`,
    ///     e.g. the rules_swift worker).
    ///   * The target's own archive (`lib<target>.a`): it carries the preview
    ///     file plus any `@main` object, both of which the JIT compiles fresh /
    ///     must not link.
    private func findDependencyArchiveFlags(
        target: String, platform: PreviewPlatform
    ) async throws -> [String] {
        let platformArgs = platformFlags(for: platform)

        let depLibs =
            (try? await runBazelQuery(
                "kind(\"(swift|objc)_library\", deps(\(target)))")) ?? ""
        let labels = depLibs.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("//") }
        if !labels.isEmpty {
            try await runBazel(["bazel", "build"] + labels + platformArgs)
        }

        let output =
            (try? await runBazel(
                ["bazel", "cquery", "deps(\(target))", "--output=files"]
                    + platformArgs, discardStderr: true)) ?? ""

        let ownArchive = "lib\(target.split(separator: ":").last.map(String.init) ?? target).a"

        var flags: [String] = []
        var seenDir = Set<String>()
        for line in output.split(separator: "\n").map(String.init) {
            let path = line.trimmingCharacters(in: .whitespaces)
            guard path.hasSuffix(".a") else { continue }
            let base = URL(fileURLWithPath: path).lastPathComponent
            guard base.hasPrefix("lib"), base != ownArchive else { continue }
            if Self.isExecConfigPath(path) { continue }
            let dir = resolveExecrootPath(path).deletingLastPathComponent().path
            if seenDir.insert(dir).inserted { flags += ["-L", dir] }
            flags += ["-l\(base.dropFirst(3).dropLast(2))"]
        }
        return flags
    }

    /// True if `path` is a Bazel output in an exec configuration (its
    /// `bazel-out/<config>/...` config segment contains an `exec` mnemonic, e.g.
    /// `darwin_arm64-opt-exec` or `darwin_arm64-opt-exec-ST-<hash>`). Such
    /// outputs are build tooling, not runtime dependencies.
    private static func isExecConfigPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let i = parts.firstIndex(of: "bazel-out"), i + 1 < parts.count
        else { return false }
        return parts[i + 1].split(separator: "-").contains("exec")
    }

    // MARK: - Private: Source Files (Tier 2)

    /// Collect all source files for the target, excluding the preview file.
    ///
    /// Unlike SPM and Xcode, we do not walk a "DerivedSources" directory for
    /// auto-generated Swift files. rules_swift's `swift_library` does not
    /// synthesize a `Bundle.module` accessor for resources — `apple_resource_bundle`
    /// yields a separate bundle reached via `Bundle(identifier:)` or a
    /// hand-written accessor. Known gaps this method does not cover:
    ///   * `swift_proto_library` / `swift_grpc_library` emit `.swift` under
    ///     `bazel-bin/<pkg>/<name>.proto_library/`.
    ///   * Consumer macros that produce adjacent `.swift` outputs.
    /// If those cases need to be previewed, extend by querying
    /// `labels(outs, <target>)` or `bazel cquery --output=files <target>` and
    /// unioning any `.swift` outputs with the `srcs` result below.
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
            if url.path == sourceFile.path { continue }
            // Exclude `@main` entry-point files: their app-lifecycle entry
            // symbol poisons the preview JIT link, and the preview never needs
            // the app entry point.
            if Self.declaresMainEntry(url) { continue }
            sourceFiles.append(url)
        }

        return sourceFiles.isEmpty ? nil : sourceFiles
    }

    /// True if `file` declares an `@main` entry point at the start of a line.
    private static func declaresMainEntry(_ file: URL) -> Bool {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else {
            return false
        }
        return text.range(of: #"(?m)^[ \t]*@main\b"#, options: .regularExpression)
            != nil
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
            // Pin the deployment target to match the bridge compile triple
            // (`Platform.macOS` -> macosx14.0), so dependency modules built by
            // Bazel do not come out at the SDK-default min (e.g. 26.2) and fail
            // to load against the 14.0 bridge.
            return ["--macos_minimum_os=14.0"]
        case .iOS:
            // The real iOS-simulator transition needs `--platforms` (the legacy
            // `--cpu`/`--apple_platform_type` flags name the output dir but do
            // NOT apply the Apple SDK transition to a bare `swift_library`,
            // leaving deps built against the macOS SDK). The platform lives in
            // the apple_support repo, whose name varies per project (default
            // `apple_support`, but e.g. the study uses `repo_name =
            // "build_bazel_apple_support"`), so resolve it from MODULE.bazel.
            // Pin the deployment target to match the bridge compile triple
            // (`Platform.iOS` -> ios17.0): a bare swift_library otherwise gets
            // the SDK-default min (e.g. 26.2), which fails to load against the
            // 17.0 bridge ("module has a minimum deployment target of iOS 26.2").
            return [
                "--platforms=@\(appleSupportRepoName())//platforms:ios_sim_arm64",
                "--ios_minimum_os=17.0",
            ]
        }
    }

    /// Resolve the repo name the project exposes for the `apple_support` module,
    /// so `--platforms=@<repo>//platforms:ios_sim_arm64` resolves. Reads the
    /// `bazel_dep(name = "apple_support", ... repo_name = "...")` from
    /// MODULE.bazel; defaults to `apple_support` (the module's own name).
    private func appleSupportRepoName() -> String {
        let moduleFile = projectRoot.appendingPathComponent("MODULE.bazel")
        guard let text = try? String(contentsOf: moduleFile, encoding: .utf8) else {
            return "apple_support"
        }
        // Match the `bazel_dep(...)` call that names apple_support, then its
        // optional `repo_name`. The call may span multiple lines.
        guard
            let depRange = text.range(
                of: #"bazel_dep\([^)]*name\s*=\s*"apple_support"[^)]*\)"#,
                options: .regularExpression)
        else {
            return "apple_support"
        }
        let depCall = text[depRange]
        if let rnRange = depCall.range(
            of: #"repo_name\s*=\s*"([^"]+)""#, options: .regularExpression)
        {
            let match = depCall[rnRange]
            if let q1 = match.range(of: "\""),
                let q2 = match.range(
                    of: "\"", options: .backwards,
                    range: q1.upperBound..<match.endIndex)
            {
                return String(match[q1.upperBound..<q2.lowerBound])
            }
        }
        return "apple_support"
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
    ///
    /// On nonzero exit, the thrown `BuildSystemError.buildFailed` carries the
    /// full command line, both captured streams (or `(empty)` placeholders),
    /// and the pwd. The previous shape — `output.stderr.isEmpty ? output.stdout
    /// : output.stderr` — discarded one stream and yielded a blank diagnostic
    /// when both streams were empty (CI run 25243519727 surfaced exactly this:
    /// bazel exited 7 with no captured output, leaving the test failure
    /// message as just "Project build failed (exit code 7):" with nothing
    /// after the colon).
    @discardableResult
    private func runBazel(
        _ arguments: [String], discardStderr: Bool = false
    ) async throws -> String {
        let output = try await runAsync(
            "/usr/bin/env", arguments: arguments,
            workingDirectory: projectRoot, discardStderr: discardStderr)
        guard output.exitCode == 0 else {
            let cmd = arguments.joined(separator: " ")
            let stderrSection = output.stderr.isEmpty ? "(empty)" : output.stderr
            let stdoutSection = output.stdout.isEmpty ? "(empty)" : output.stdout
            let diagnostic = """
                command: \(cmd)
                cwd: \(projectRoot.path)
                stderr:
                \(stderrSection)
                stdout:
                \(stdoutSection)
                """
            throw BuildSystemError.buildFailed(
                stderr: diagnostic,
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }
}

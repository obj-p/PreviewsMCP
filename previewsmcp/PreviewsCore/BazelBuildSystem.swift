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
                        projectRoot: dir, sourceFile: sourceFile.standardizedFileURL
                    )
                }
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }

    // MARK: - Ownership

    /// Confirm membership via the workspace's own model: a package-scoped
    /// `rdeps` query for a swift_library whose srcs include the file. Broad
    /// universes are never queried; a workspace-wide query loads every
    /// package.
    static func confirmOwnership(
        projectRoot: URL, sourceFile: URL
    ) async -> OwnershipVerdict {
        guard await isBazelAvailable(in: projectRoot) else {
            return .indeterminate(
                reason: "bazel workspace marker found but bazel is not runnable here"
            )
        }
        let system = BazelBuildSystem(projectRoot: projectRoot, sourceFile: sourceFile)
        return await system.confirmOwnership()
    }

    private func confirmOwnership() async -> OwnershipVerdict {
        let packagePath: String
        do {
            packagePath = try findBazelPackage(for: sourceFile)
        } catch {
            return .notMember(
                reason:
                "no BUILD file between \(sourceFile.lastPathComponent) and the workspace root"
            )
        }
        let sourceLabel = buildSourceLabel(packagePath: packagePath, sourceFile: sourceFile)
        let query = "kind(\"swift_library\", rdeps(//\(packagePath):all, \(sourceLabel)))"
        let output: String
        do {
            output = try await runBazel(["bazel", "query", query])
        } catch {
            let message = (error as? BuildSystemError)?.errorDescription
                ?? error.localizedDescription
            // "no such target/package" is the workspace answering "not mine"
            // (e.g. the file sits under a .bazelignore'd path); only
            // infrastructure failures are indeterminate.
            let notMine = ["no such target", "no targets found", "no such package"]
            if notMine.contains(where: message.contains) {
                return .notMember(
                    reason:
                    "//\(packagePath) does not declare \(sourceFile.lastPathComponent) as a target source"
                )
            }
            let detail = message.split(separator: "\n").last.map(String.init) ?? message
            return .indeterminate(reason: "bazel query failed: \(detail)")
        }
        let targets = output.split(separator: "\n").map(String.init)
        guard let target = targets.first else {
            return .notMember(
                reason:
                "no swift_library in //\(packagePath) depends on \(sourceFile.lastPathComponent)"
            )
        }
        return .confirmed(
            Ownership(kind: .bazel, projectRoot: projectRoot, targetName: target)
        )
    }

    /// Check if bazel is available by running `bazel version`.
    private static func isBazelAvailable(in directory: URL) async -> Bool {
        do {
            let output = try await runAsync(
                "/usr/bin/env", arguments: ["bazel", "version"],
                workingDirectory: directory, discardStderr: true
            )
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
        do {
            try await runBazelBuild(target: target, platform: platform)
        } catch where platform == .iOS && Self.isModuleRedefinition(error) {
            // The top-level `--platforms` transition on a bare swift_library can
            // resolve a shared dep into two configurations at once on some
            // dependency graphs, and both emit the same unqualified modulemap —
            // swiftc rejects the duplicate (#279). Building *through* the
            // enclosing Apple bundle applies the rule's 1:1 split transition,
            // which collapses the dep to a single config.
            for bundle in await findEnclosingAppleBundles(
                target: target, packagePath: packagePath
            ) {
                guard
                    let context = try? await buildViaAppleBundle(
                        bundle: bundle, target: target, moduleName: moduleName
                    )
                else { continue }
                return context
            }
            // No candidate worked: surface the actionable original diagnostic,
            // not whichever candidate bundle happened to fail last.
            throw error
        }

        let platformArgs = platformFlags(for: platform)
        try await buildDependencyArchives(target: target, platformArgs: platformArgs)
        return try await makeBuildContext(
            target: target, expr: target, moduleName: moduleName, platformArgs: platformArgs
        )
    }

    /// Assemble the `BuildContext` for `target` after its build succeeded.
    ///
    /// `expr` is the cquery/aquery expression that selects the target in the
    /// configuration it was built under: the target itself on the default
    /// (bare-library) path, or `deps(<bundle>) intersect <target>` on the
    /// enclosing-bundle fallback.
    private func makeBuildContext(
        target: String, expr: String, moduleName: String, platformArgs: [String]
    ) async throws -> BuildContext {
        // Locate the .swiftmodule
        var compilerFlags = try await findCompilerFlags(
            target: target, expr: expr, moduleName: moduleName, platformArgs: platformArgs
        )

        // Add dependency module search paths (swift_library deps and
        // objc_library module maps) from the target's SwiftCompile action,
        // so the bridge's `import <Dep>` resolves.
        compilerFlags += try await findDependencyModuleFlags(
            expr: expr, platformArgs: platformArgs
        )

        // Add dependency archive link flags (`-L`/`-l`) for the target's
        // static-library deps, so the preview JIT link resolves their
        // cross-target symbols (`findDependencyModuleFlags` only covers the
        // compile-time module search).
        compilerFlags += try await findDependencyArchiveFlags(
            target: target, expr: expr, platformArgs: platformArgs
        )

        // Collect source files for Tier 2
        let sourceFiles = try await collectSourceFiles(target: target)

        return BuildContext(
            moduleName: moduleName,
            compilerFlags: compilerFlags,
            projectRoot: projectRoot,
            targetName: moduleName,
            sourceFiles: sourceFiles
        )
    }

    /// True if `error` is a build failure whose diagnostics contain swiftc's
    /// cross-config duplicate-modulemap signature (#279).
    static func isModuleRedefinition(_ error: Error) -> Bool {
        guard case let BuildSystemError.buildFailed(stderr, _) = error else {
            return false
        }
        return stderr.contains("redefinition of module")
    }

    /// Apple bundle rules (application/framework/extension) that depend on
    /// `target`, to rebuild through on the #279 fallback; capped at 3
    /// candidates since each attempt is a full bundle build. Tries the
    /// target's package subtree first (bundles are usually colocated, and
    /// `rdeps` over `//...` loads every package in exactly the monorepos this
    /// fallback targets), then widens to the whole workspace. The kind regex
    /// is end-anchored so import rules (`apple_static_framework_import`, ...)
    /// that merely contain "framework" do not match. Total query failure
    /// resolves to [] so the caller rethrows the original build error.
    private func findEnclosingAppleBundles(
        target: String, packagePath: String
    ) async -> [String] {
        var universes = ["//..."]
        if !packagePath.isEmpty {
            universes.insert("//\(packagePath)/...", at: 0)
        }
        for universe in universes {
            let query =
                #"kind("^(ios|apple)_.*(application|framework|extension) rule$", "#
                    + "rdeps(\(universe), \(target)))"
            let bundles = await runPartialBazelQuery(query)
                .split(separator: "\n").map(String.init)
                .filter { $0.hasPrefix("//") }
            if !bundles.isEmpty {
                return Array(bundles.prefix(3))
            }
        }
        return []
    }

    /// `bazel query --keep_going`, tolerating exit code 3 (valid partial
    /// results after skipping broken packages in the universe) so one broken
    /// unrelated package cannot hide an existing enclosing bundle.
    private func runPartialBazelQuery(_ query: String) async -> String {
        guard
            let output = try? await runAsync(
                "/usr/bin/env",
                arguments: ["bazel", "query", query, "--keep_going"],
                workingDirectory: projectRoot, discardStderr: true
            ),
            output.exitCode == 0 || output.exitCode == 3
        else { return "" }
        return output.stdout
    }

    /// #279 fallback: build `bundle` with the simulator split transition
    /// (`--ios_multi_cpus`), which configures `target`'s dependency closure in
    /// exactly one config, then derive all flags from that closure. The bare
    /// library cannot take `--ios_multi_cpus` at top level itself (Apple rules
    /// like `apple_dynamic_xcframework_import` need the platform from a rule
    /// transition, not a CLI flag). No `buildDependencyArchives` here: the
    /// bundle's link step already materialized every dependency archive.
    private func buildViaAppleBundle(
        bundle: String, target: String, moduleName: String
    ) async throws -> BuildContext {
        let platformArgs = ["--ios_multi_cpus=sim_arm64", Self.iosMinimumOSFlag]
        try await runBazel(["bazel", "build", bundle] + platformArgs)

        // filter(), not `intersect <target>`: a bare target pattern in the
        // expression would be configured at TOP level (no rule transition) —
        // the very analysis that fails on these graphs. filter() selects the
        // library from inside the bundle's already-configured closure.
        let escaped = NSRegularExpression.escapedPattern(for: target)
        return try await makeBuildContext(
            target: target,
            expr: "filter(\"^\(escaped)$\", deps(\(bundle)))",
            moduleName: moduleName,
            platformArgs: platformArgs
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
                    return String(dir.path.dropFirst(rootPath.count))
                        .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
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
        let fileComponent: String = if filePath.hasPrefix(packageDirPath + "/") {
            String(filePath.dropFirst(packageDirPath.count + 1))
        } else {
            sourceFile.lastPathComponent
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
               let quoteEnd = match.range(
                   of: "\"",
                   options: .backwards,
                   range: quoteStart.upperBound ..< match.endIndex
               )
            {
                return String(match[quoteStart.upperBound ..< quoteEnd.lowerBound])
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
        target: String, expr: String, moduleName: String, platformArgs: [String]
    ) async throws -> [String] {
        var args = ["bazel", "cquery", "--output=files", expr]
        args += platformArgs

        let output = try await runBazel(args, discardStderr: true)

        // Find the .swiftmodule file in the output, preferring a target-config
        // one (the fallback closure can also carry an exec-config copy) but
        // keeping the pre-#279 any-match behavior as the backstop.
        let files = output.split(separator: "\n").map(String.init)
        let swiftmodules = files.filter { $0.hasSuffix(".swiftmodule") }
        let swiftmoduleFile =
            swiftmodules.first { !Self.isExecConfigPath($0) } ?? swiftmodules.first

        if let swiftmodulePath = swiftmoduleFile {
            // Resolve to absolute path (cquery may return relative paths from execroot)
            let absolutePath: URL = if swiftmodulePath.hasPrefix("/") {
                URL(fileURLWithPath: swiftmodulePath)
            } else {
                projectRoot.appendingPathComponent(swiftmodulePath)
            }
            return ["-I", absolutePath.deletingLastPathComponent().path]
        }

        // The bazel-bin symlink tracks the default config; on the bundle
        // fallback the artifacts live under the split-transition output dir,
        // so a bazel-bin hit could only be a stale module from another config.
        guard expr == target else {
            throw BuildSystemError.missingArtifacts(
                "Expected \(moduleName).swiftmodule in cquery output for \(expr)"
            )
        }

        // Fallback: try bazel-bin symlink + package path
        let bazelBin = projectRoot.appendingPathComponent("bazel-bin")
        let moduleDir = bazelBin.appendingPathComponent(
            target.replacingOccurrences(of: "//", with: "")
                .split(separator: ":").first.map(String.init) ?? ""
        )
        try BuildSystemSupport.verifySwiftModule(named: moduleName, in: moduleDir) {
            BuildSystemError.missingArtifacts(
                "Expected \(moduleName).swiftmodule in bazel-bin output for \(target)"
            )
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
        expr: String, platformArgs: [String]
    ) async throws -> [String] {
        var args = ["bazel", "aquery", "mnemonic(\"SwiftCompile\", \(expr))"]
        args += platformArgs
        let output = (try? await runBazel(args, discardStderr: true)) ?? ""

        func resolve(_ path: String) -> String {
            resolveExecrootPath(path).path
        }

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

    /// Build the target's dependency libraries so their static archives are on
    /// disk before `findDependencyArchiveFlags` scans for them: building
    /// `target` alone materializes its dependency swiftmodules but not their
    /// archives (a `swift_library` build has no link step).
    private func buildDependencyArchives(
        target: String, platformArgs: [String]
    ) async throws {
        let depLibs =
            (try? await runBazelQuery(
                "kind(\"(swift|objc)_library\", deps(\(target)))"
            )) ?? ""
        let labels = depLibs.split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("//") }
        if !labels.isEmpty {
            try await runBazel(["bazel", "build"] + labels + platformArgs)
        }
    }

    /// Extract `-L <dir>` / `-l<name>` link flags for the target's dependency
    /// static archives (`libSwiftLib.a`, `libObjCLib.a`), so the preview JIT
    /// link resolves their cross-target symbols.
    ///
    /// `deps(<expr>)` also returns two kinds of archives that must NOT be
    /// linked, filtered here:
    ///   * Build tooling in the exec configuration (see `isExecConfigPath`,
    ///     e.g. the rules_swift worker).
    ///   * The target's own archive (`lib<target>.a`): it carries the preview
    ///     file plus any `@main` object, both of which the JIT compiles fresh /
    ///     must not link.
    private func findDependencyArchiveFlags(
        target: String, expr: String, platformArgs: [String]
    ) async throws -> [String] {
        let output =
            (try? await runBazel(
                ["bazel", "cquery", "deps(\(expr))", "--output=files"]
                    + platformArgs, discardStderr: true
            )) ?? ""

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

        let packagePath = String(label[label.startIndex ..< colonIndex])
        let fileName = String(label[label.index(after: colonIndex)...])

        if packagePath.isEmpty {
            return fileName
        }
        return "\(packagePath)/\(fileName)"
    }

    // MARK: - Private: Platform Flags

    /// Deployment-target pin shared by both iOS build paths, matching the
    /// bridge compile triple (`Platform.iOS` -> ios17.0): dependency modules
    /// otherwise come out at the SDK-default min (e.g. 26.2) and fail to load
    /// against the 17.0 bridge ("module has a minimum deployment target of
    /// iOS 26.2"). On the bundle fallback, a bundle's own `minimum_os_version`
    /// attribute still takes precedence over this flag.
    private static let iosMinimumOSFlag = "--ios_minimum_os=17.0"

    private func platformFlags(for platform: PreviewPlatform) -> [String] {
        switch platform {
        case .macOS:
            // Pin the deployment target to match the bridge compile triple
            // (`Platform.macOS` -> macosx14.0), so dependency modules built by
            // Bazel do not come out at the SDK-default min (e.g. 26.2) and fail
            // to load against the 14.0 bridge.
            ["--macos_minimum_os=14.0"]
        case .iOS:
            // The real iOS-simulator transition needs `--platforms` (the legacy
            // `--cpu`/`--apple_platform_type` flags name the output dir but do
            // NOT apply the Apple SDK transition to a bare `swift_library`,
            // leaving deps built against the macOS SDK). The platform lives in
            // the apple_support repo, whose name varies per project (default
            // `apple_support`, but e.g. the study uses `repo_name =
            // "build_bazel_apple_support"`), so resolve it from MODULE.bazel.
            [
                "--platforms=@\(appleSupportRepoName())//platforms:ios_sim_arm64",
                Self.iosMinimumOSFlag,
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
                options: .regularExpression
            )
        else {
            return "apple_support"
        }
        let depCall = text[depRange]
        if let rnRange = depCall.range(
            of: #"repo_name\s*=\s*"([^"]+)""#, options: .regularExpression
        ) {
            let match = depCall[rnRange]
            if let q1 = match.range(of: "\""),
               let q2 = match.range(
                   of: "\"", options: .backwards,
                   range: q1.upperBound ..< match.endIndex
               )
            {
                return String(match[q1.upperBound ..< q2.lowerBound])
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
            workingDirectory: projectRoot, discardStderr: discardStderr
        )
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

import Foundation

/// Error from a failed compilation.
public struct CompilationError: Error, LocalizedError, CustomStringConvertible {
    public let message: String
    public let stderr: String
    public let exitCode: Int32

    public var description: String {
        """
        Compilation failed (exit code \(exitCode)):
        \(message)
        \(stderr)
        """
    }

    public var errorDescription: String? { description }
}

/// Compiles Swift source code into object files for the JIT render path.
public actor Compiler {
    private let workDir: URL
    nonisolated let sdkPath: String
    private let swiftcPath: String
    public nonisolated let platform: PreviewPlatform
    private let targetTriple: String
    private let moduleCachePath: URL

    /// Create a compiler with a work directory for build artifacts.
    /// Resolves SDK and swiftc paths from the active Xcode toolchain.
    public init(workDir: URL? = nil, platform: PreviewPlatform = .macOS) async throws {
        self.platform = platform

        let dir =
            workDir
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir

        self.sdkPath = try await Toolchain.sdkPath(for: platform)
        self.targetTriple = platform.targetTriple
        self.swiftcPath = try await Toolchain.swiftcPath()

        // Shared module cache at parent of workDir, keyed by platform to avoid SDK conflicts.
        let cacheDir =
            dir.deletingLastPathComponent()
            .appendingPathComponent("ModuleCache-\(platform)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.moduleCachePath = cacheDir
    }

    private var compilationCounter = 0

    public func compileObject(
        source: String,
        moduleName: String,
        extraFlags: [String] = [],
        overrideSDK: String? = nil
    ) async throws -> URL {
        compilationCounter += 1
        let uniqueName = "\(moduleName)_\(compilationCounter)"
        let sourceFile = workDir.appendingPathComponent("\(uniqueName).swift")
        let objectFile = workDir.appendingPathComponent("\(uniqueName).o")

        try source.write(to: sourceFile, atomically: true, encoding: .utf8)

        var args: [String] = [
            swiftcPath,
            "-emit-object",
            "-parse-as-library",
            "-target", targetTriple,
            "-sdk", try resolveSDK(overrideSDK),
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
        ]
        args += extraFlags
        args += ["-o", objectFile.path, sourceFile.path]

        try await run(args)
        return objectFile
    }

    /// A prebuilt stable module: a `.swiftmodule` (consumed at compile time via `-I modulesDir`)
    /// plus its linkable `.o` (added to the JIT alongside the per-edit editable unit).
    public struct StableModule: Sendable {
        public let moduleName: String
        public let modulesDir: URL
        public let objectPath: URL
    }

    /// Build the stable half of the recompile-narrowing split: compile `sources` once into a
    /// single whole-module `.o` plus a `-enable-testing` `.swiftmodule`. The editable unit then
    /// compiles a single file against this prebuilt module (`-I modulesDir`, `@testable import`),
    /// so an edit never re-parses the bulk.
    public func emitStableModule(
        sources: [String],
        moduleName: String,
        extraFlags: [String] = [],
        overrideSDK: String? = nil
    ) async throws -> StableModule {
        compilationCounter += 1
        let moduleDir = workDir.appendingPathComponent(
            "stable-\(moduleName)-\(compilationCounter)", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)

        var sourceFiles: [URL] = []
        for (index, source) in sources.enumerated() {
            let file = moduleDir.appendingPathComponent("bulk_\(index).swift")
            try source.write(to: file, atomically: true, encoding: .utf8)
            sourceFiles.append(file)
        }

        return try await emitStableModule(
            sourceFiles: sourceFiles, moduleName: moduleName, moduleDir: moduleDir,
            extraFlags: extraFlags, overrideSDK: overrideSDK)
    }

    /// File-based variant: compile existing project sources in place (their real paths) into
    /// the stable module, without copying. Used by the Tier-2 recompile-narrowing split.
    public func emitStableModule(
        sourceFiles: [URL],
        moduleName: String,
        extraFlags: [String] = [],
        overrideSDK: String? = nil
    ) async throws -> StableModule {
        compilationCounter += 1
        let moduleDir = workDir.appendingPathComponent(
            "stable-\(moduleName)-\(compilationCounter)", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        return try await emitStableModule(
            sourceFiles: sourceFiles, moduleName: moduleName, moduleDir: moduleDir,
            extraFlags: extraFlags, overrideSDK: overrideSDK)
    }

    private func emitStableModule(
        sourceFiles: [URL],
        moduleName: String,
        moduleDir: URL,
        extraFlags: [String],
        overrideSDK: String?
    ) async throws -> StableModule {
        let objectFile = moduleDir.appendingPathComponent("\(moduleName).o")
        let moduleFile = moduleDir.appendingPathComponent("\(moduleName).swiftmodule")

        var args: [String] = [
            swiftcPath,
            "-wmo",
            "-emit-object",
            "-parse-as-library",
            "-enable-testing",
            "-target", targetTriple,
            "-sdk", try resolveSDK(overrideSDK),
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
            "-emit-module-path", moduleFile.path,
        ]
        args += extraFlags
        args += ["-o", objectFile.path]
        args += sourceFiles.map(\.path)

        try await run(args)
        return StableModule(moduleName: moduleName, modulesDir: moduleDir, objectPath: objectFile)
    }

    /// Per-module incremental build directory, reused across edits so the driver's
    /// `.swiftdeps` records and the unchanged-file objects persist between compiles.
    private var incrementalDirs: [String: URL] = [:]

    /// The overlay's `swift-frontend` argv, captured once from the driver's own compile plan and
    /// replayed verbatim on later edits. The driver only spawns the frontend after a round of job
    /// planning and `.swiftdeps` bookkeeping; replaying the frontend job directly skips that.
    /// Reusable verbatim because the overlay path and output stay constant per module — only the
    /// overlay file's contents change. The fingerprint regenerates the template (and rebuilds the
    /// bulk objects via the driver) if the build context (target, sdk, flags) or any bulk file
    /// changes — the bypass only recompiles the overlay, so a stale bulk object would otherwise
    /// be reused.
    private var frontendTemplates: [String: (fingerprint: String, argv: [String])] = [:]

    /// Compile the whole target module incrementally: the editable `overlaySource` plus the
    /// target's other `bulkFiles`, all under one `moduleName`. The Swift driver recompiles only
    /// what changed — the overlay alone on a body edit, the overlay plus its dependents on an
    /// interface edit — and reuses the rest from the persistent build dir. Returns the overlay's
    /// object and the bulk objects (in `bulkFiles` order). This is the non-leaf structural split:
    /// the bulk references the edited file, so a one-directional prebuilt stable module cannot be
    /// used, but a single module resolves references in both directions.
    public func compileModuleIncremental(
        overlaySource: String,
        bulkFiles: [URL],
        moduleName: String,
        extraFlags: [String] = [],
        overrideSDK: String? = nil
    ) async throws -> (overlayObject: URL, bulkObjects: [URL]) {
        try await compileModuleIncremental(
            overlaySource: overlaySource, bulkFiles: bulkFiles, moduleName: moduleName,
            extraFlags: extraFlags, overrideSDK: overrideSDK, bypassDriver: true)
    }

    /// `bypassDriver` is an internal seam: production always bypasses; tests pass `false` to
    /// measure the driver baseline against the bypass.
    func compileModuleIncremental(
        overlaySource: String,
        bulkFiles: [URL],
        moduleName: String,
        extraFlags: [String] = [],
        overrideSDK: String? = nil,
        bypassDriver: Bool
    ) async throws -> (overlayObject: URL, bulkObjects: [URL]) {
        let dir: URL
        if let existing = incrementalDirs[moduleName] {
            dir = existing
        } else {
            dir = workDir.appendingPathComponent("incremental-\(moduleName)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            incrementalDirs[moduleName] = dir
        }

        let overlayFile = dir.appendingPathComponent("overlay.swift")
        try overlaySource.write(to: overlayFile, atomically: true, encoding: .utf8)
        let overlayObject = dir.appendingPathComponent("overlay.o")

        // The output-file-map keys must match the command-line paths exactly, or the driver
        // disables incremental ("no swiftDeps file") and recompiles everything every edit.
        var fileMap: [String: [String: String]] = [
            "": ["swift-dependencies": dir.appendingPathComponent("master.swiftdeps").path],
            overlayFile.path: [
                "object": overlayObject.path,
                "swift-dependencies": dir.appendingPathComponent("overlay.swiftdeps").path,
            ],
        ]
        var bulkObjects: [URL] = []
        for (index, file) in bulkFiles.enumerated() {
            let object = dir.appendingPathComponent("bulk_\(index).o")
            bulkObjects.append(object)
            fileMap[file.path] = [
                "object": object.path,
                "swift-dependencies": dir.appendingPathComponent("bulk_\(index).swiftdeps").path,
            ]
        }
        let mapFile = dir.appendingPathComponent("output-file-map.json")
        let mapData = try JSONSerialization.data(withJSONObject: fileMap, options: [.sortedKeys])
        try mapData.write(to: mapFile)

        var args: [String] = [
            swiftcPath,
            "-incremental",
            "-emit-object",
            "-parse-as-library",
            "-target", targetTriple,
            "-sdk", try resolveSDK(overrideSDK),
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
            "-output-file-map", mapFile.path,
        ]
        args += extraFlags
        args += [overlayFile.path]
        args += bulkFiles.map(\.path)

        let bulkStamps = bulkFiles.map { url -> String in
            let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
            let mtime = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
            let size = (attrs?[.size] as? Int) ?? 0
            return "\(url.path)@\(mtime):\(size)"
        }
        let fingerprint = (args.dropFirst() + bulkStamps).joined(separator: "\u{1f}")

        if bypassDriver, let cached = frontendTemplates[moduleName], cached.fingerprint == fingerprint {
            do {
                try await run(cached.argv)
                return (overlayObject, bulkObjects)
            } catch {
                Log.warn("jit_latency: frontend bypass failed, falling back to driver (\(error))")
                frontendTemplates[moduleName] = nil
            }
        }

        try await run(args)

        if bypassDriver {
            if let argv = try? await captureOverlayFrontendJob(
                moduleName: moduleName, overlayFile: overlayFile, overlayObject: overlayObject,
                bulkFiles: bulkFiles, extraFlags: extraFlags, overrideSDK: overrideSDK)
            {
                frontendTemplates[moduleName] = (fingerprint, argv)
            }
        }
        return (overlayObject, bulkObjects)
    }

    /// Ask the driver (`-###`) for the `swift-frontend` job it would run to compile the overlay as
    /// the single primary file, then rewrite that job's `-o` to the overlay object. Captured
    /// without `-incremental`/`-output-file-map` so the plan never depends on stale `.swiftdeps`
    /// state and always prints one `-primary-file` job per source. The bulk files stay as secondary
    /// inputs (parsed, not emitted), which preserves the two-way reference resolution the single
    /// module relies on. Returns nil if the overlay job can't be found, so the caller keeps using
    /// the driver.
    private func captureOverlayFrontendJob(
        moduleName: String,
        overlayFile: URL,
        overlayObject: URL,
        bulkFiles: [URL],
        extraFlags: [String],
        overrideSDK: String?
    ) async throws -> [String]? {
        var capture: [String] = [
            swiftcPath,
            "-###",
            "-emit-object",
            "-parse-as-library",
            "-target", targetTriple,
            "-sdk", try resolveSDK(overrideSDK),
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
        ]
        capture += extraFlags
        capture += [overlayFile.path]
        capture += bulkFiles.map(\.path)

        let plan = try await run(capture)
        for line in plan.split(whereSeparator: \.isNewline) {
            let toks = Self.shellSplit(String(line))
            guard let pf = toks.firstIndex(of: "-primary-file"), pf + 1 < toks.count,
                toks[pf + 1] == overlayFile.path,
                let o = toks.firstIndex(of: "-o"), o + 1 < toks.count
            else { continue }
            var argv = toks
            argv[o + 1] = overlayObject.path
            return argv
        }
        return nil
    }

    /// Split a `-###` plan line into argv. The driver shell-quotes only tokens with special
    /// characters (e.g. `-external-plugin-path` values containing `#`), so this honors single
    /// quotes, double quotes, and backslash escapes.
    private static func shellSplit(_ line: String) -> [String] {
        let chars = Array(line)
        var tokens: [String] = []
        var cur = ""
        var hasToken = false
        var inSingle = false
        var inDouble = false
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if inSingle {
                if c == "'" { inSingle = false } else { cur.append(c) }
            } else if inDouble {
                if c == "\"" {
                    inDouble = false
                } else if c == "\\", i + 1 < chars.count {
                    i += 1
                    cur.append(chars[i])
                } else {
                    cur.append(c)
                }
            } else if c == "'" {
                inSingle = true
                hasToken = true
            } else if c == "\"" {
                inDouble = true
                hasToken = true
            } else if c == "\\", i + 1 < chars.count {
                i += 1
                cur.append(chars[i])
                hasToken = true
            } else if c == " " || c == "\t" {
                if hasToken {
                    tokens.append(cur)
                    cur = ""
                    hasToken = false
                }
            } else {
                cur.append(c)
                hasToken = true
            }
            i += 1
        }
        if hasToken { tokens.append(cur) }
        return tokens
    }

    // MARK: - Private

    /// Resolve the SDK for a compile, honoring a setup-module override. Layer 3 guard for
    /// issue #170: if the override SDK no longer exists (e.g. user upgraded Xcode after a
    /// SetupBuilder build landed in cache), fail fast with an actionable error before swiftc
    /// surfaces a generic "cannot find SDK" diagnostic that doesn't hint at cache staleness.
    private func resolveSDK(_ overrideSDK: String?) throws -> String {
        guard let overrideSDK else { return sdkPath }
        guard FileManager.default.fileExists(atPath: overrideSDK) else {
            throw CompilationError(
                message:
                    "Setup module was built against SDK at \(overrideSDK), which "
                    + "no longer exists on disk. The active toolchain resolves to "
                    + "\(sdkPath). Delete the setup cache (.build/previewsmcp-setup-cache) "
                    + "or rebuild the setup package to capture the current SDK.",
                stderr: "",
                exitCode: 1
            )
        }
        if overrideSDK != sdkPath {
            Log.warn(
                "compile: setup SDK differs from active toolchain SDK "
                    + "(setup=\(overrideSDK), default=\(sdkPath)). Inheriting setup "
                    + "SDK to keep swiftmodule load consistent.")
        }
        return overrideSDK
    }

    @discardableResult
    private func run(_ args: [String]) async throws -> String {
        let output = try await runAsync(args[0], arguments: Array(args.dropFirst()))
        guard output.exitCode == 0 else {
            throw CompilationError(
                message: "Command failed: \(args.joined(separator: " "))",
                stderr: output.stderr,
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }

}

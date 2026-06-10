import Foundation

/// Result of a successful compilation.
public struct CompilationResult: Sendable {
    /// Path to the compiled and signed dylib.
    public let dylibPath: URL
    /// Any compiler warnings (stderr output that didn't cause failure).
    public let diagnostics: String
}

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

/// Compiles Swift source code into signed dynamic libraries.
public actor Compiler {
    private let workDir: URL
    nonisolated let sdkPath: String
    private let swiftcPath: String
    private let codesignPath: String
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
        self.codesignPath = try await Toolchain.codesignPath()

        // Shared module cache at parent of workDir, keyed by platform to avoid SDK conflicts.
        let cacheDir =
            dir.deletingLastPathComponent()
            .appendingPathComponent("ModuleCache-\(platform)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.moduleCachePath = cacheDir
    }

    private var compilationCounter = 0

    /// Compile combined source (original + bridge) into a signed dylib.
    /// Each compilation produces a uniquely-named dylib so dlopen loads fresh code.
    ///
    /// - Parameters:
    ///   - source: The Swift source code to compile.
    ///   - moduleName: The module name for the compilation unit.
    ///   - extraFlags: Additional swiftc flags (e.g., -I, -L from build system).
    ///   - additionalSourceFiles: Extra .swift files to compile alongside (Tier 2 project mode).
    ///   - overrideSDK: Optional SDK path to use instead of the Compiler's default.
    ///     When the bridge imports a swiftmodule built externally (the user's
    ///     setup package, compiled by SetupBuilder), the import will fail with
    ///     "cannot load module ... built with SDK 'X' when using SDK 'Y'" if
    ///     the two compilations disagreed on the SDK. Inheriting the setup's
    ///     SDK here makes the import succeed by construction (issue #170).
    public func compileCombined(
        source: String,
        moduleName: String,
        extraFlags: [String] = [],
        additionalSourceFiles: [URL] = [],
        overrideSDK: String? = nil
    ) async throws -> CompilationResult {
        compilationCounter += 1
        let uniqueName = "\(moduleName)_\(compilationCounter)"
        let sourceFile = workDir.appendingPathComponent("\(uniqueName).swift")
        let dylibFile = workDir.appendingPathComponent("\(uniqueName).dylib")
        let effectiveSDK = overrideSDK ?? sdkPath

        // Layer 3 guard for issue #170: if the caller passes an SDK that no
        // longer exists (e.g. user upgraded Xcode after a SetupBuilder build
        // landed in cache, or hand-supplied a bogus path), fail fast with an
        // actionable error before swiftc surfaces a generic "cannot find SDK"
        // diagnostic that doesn't hint at the cache-staleness root cause.
        if let overrideSDK, !FileManager.default.fileExists(atPath: overrideSDK) {
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

        if let overrideSDK, overrideSDK != sdkPath {
            Log.warn(
                "compileCombined: setup SDK differs from active toolchain SDK "
                    + "(setup=\(overrideSDK), default=\(sdkPath)). Inheriting setup "
                    + "SDK to keep swiftmodule load consistent.")
        }

        Log.info(
            "compileCombined: module=\(moduleName) platform=\(platform) "
                + "sdk=\(effectiveSDK) "
                + "extraFlags=\(extraFlags.joined(separator: " ")) "
                + "additionalSources=\(additionalSourceFiles.count) "
                + "dylib=\(dylibFile.path)")

        try source.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Build argument list
        var args: [String] = [
            swiftcPath,
            "-emit-library",
            "-parse-as-library",
            "-target", targetTriple,
            "-sdk", effectiveSDK,
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
        ]
        args += extraFlags
        args += ["-o", dylibFile.path, sourceFile.path]
        args += additionalSourceFiles.map(\.path)

        try await run(args)

        // Ad-hoc codesign (required on Apple Silicon)
        try await run([codesignPath, "-s", "-", dylibFile.path])

        return CompilationResult(dylibPath: dylibFile, diagnostics: "")
    }

    public func compileObject(
        source: String,
        moduleName: String,
        extraFlags: [String] = []
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
            "-sdk", sdkPath,
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
        extraFlags: [String] = []
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
            extraFlags: extraFlags)
    }

    /// File-based variant: compile existing project sources in place (their real paths) into
    /// the stable module, without copying. Used by the Tier-2 recompile-narrowing split.
    public func emitStableModule(
        sourceFiles: [URL],
        moduleName: String,
        extraFlags: [String] = []
    ) async throws -> StableModule {
        compilationCounter += 1
        let moduleDir = workDir.appendingPathComponent(
            "stable-\(moduleName)-\(compilationCounter)", isDirectory: true)
        try FileManager.default.createDirectory(at: moduleDir, withIntermediateDirectories: true)
        return try await emitStableModule(
            sourceFiles: sourceFiles, moduleName: moduleName, moduleDir: moduleDir,
            extraFlags: extraFlags)
    }

    private func emitStableModule(
        sourceFiles: [URL],
        moduleName: String,
        moduleDir: URL,
        extraFlags: [String]
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
            "-sdk", sdkPath,
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
        extraFlags: [String] = []
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
            "-sdk", sdkPath,
            "-module-name", moduleName,
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
            "-output-file-map", mapFile.path,
        ]
        args += extraFlags
        args += [overlayFile.path]
        args += bulkFiles.map(\.path)

        try await run(args)
        return (overlayObject, bulkObjects)
    }

    // MARK: - Private

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

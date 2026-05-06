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

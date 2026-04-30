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
    private let sdkPath: String
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

        switch platform {
        case .macOS:
            self.sdkPath = try await Self.resolve("xcrun", "--show-sdk-path")
        case .iOS:
            self.sdkPath = try await Self.resolve("xcrun", "--show-sdk-path", "--sdk", "iphonesimulator")
        }
        self.targetTriple = platform.targetTriple
        self.swiftcPath = try await Self.resolve("xcrun", "--find", "swiftc")
        self.codesignPath = try await Self.resolve("xcrun", "--find", "codesign")

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
    public func compileCombined(
        source: String,
        moduleName: String,
        extraFlags: [String] = [],
        additionalSourceFiles: [URL] = []
    ) async throws -> CompilationResult {
        compilationCounter += 1
        let uniqueName = "\(moduleName)_\(compilationCounter)"
        let sourceFile = workDir.appendingPathComponent("\(uniqueName).swift")
        let dylibFile = workDir.appendingPathComponent("\(uniqueName).dylib")

        Log.info(
            "compileCombined: module=\(moduleName) platform=\(platform) "
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
            "-sdk", sdkPath,
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

    private static func resolve(_ args: String...) async throws -> String {
        let output = try await runAsync("/usr/bin/env", arguments: args, discardStderr: true)
        guard output.exitCode == 0 else {
            throw CompilationError(
                message: "Failed to resolve: \(args.joined(separator: " "))",
                stderr: "",
                exitCode: output.exitCode
            )
        }
        return output.stdout
    }
}

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
            self.targetTriple = "arm64-apple-macosx14.0"
        case .iOSSimulator:
            self.sdkPath = try await Self.resolve("xcrun", "--show-sdk-path", "--sdk", "iphonesimulator")
            self.targetTriple = "arm64-apple-ios17.0-simulator"
        }
        self.swiftcPath = try await Self.resolve("xcrun", "--find", "swiftc")
        self.codesignPath = try await Self.resolve("xcrun", "--find", "codesign")
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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: args[0])
        process.arguments = Array(args.dropFirst())

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()
        process.waitUntilExit()

        let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
        let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
        let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
        let stderr = String(data: stderrData, encoding: .utf8) ?? ""

        guard process.terminationStatus == 0 else {
            throw CompilationError(
                message: "Command failed: \(args.joined(separator: " "))",
                stderr: stderr,
                exitCode: process.terminationStatus
            )
        }

        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func resolve(_ args: String...) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = args

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw CompilationError(
                message: "Failed to resolve: \(args.joined(separator: " "))",
                stderr: "",
                exitCode: process.terminationStatus
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

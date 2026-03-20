import Foundation
import PreviewsCore

/// Compiles the embedded iOS host app source into a signed .app bundle
/// for the iOS simulator.
public actor IOSHostBuilder {
    private let workDir: URL
    private let swiftcPath: String
    private let sdkPath: String
    private let codesignPath: String
    private let targetTriple: String

    private var cachedAppPath: URL?

    public init(workDir: URL? = nil) async throws {
        let dir =
            workDir
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-host", isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir
        self.targetTriple = "arm64-apple-ios17.0-simulator"

        self.sdkPath = try await Self.resolve("xcrun", "--show-sdk-path", "--sdk", "iphonesimulator")
        self.swiftcPath = try await Self.resolve("xcrun", "--find", "swiftc")
        self.codesignPath = try await Self.resolve("xcrun", "--find", "codesign")
    }

    /// Build the iOS host app, returning the path to the .app bundle.
    /// Caches the result — subsequent calls return the cached path.
    public func ensureHostApp() async throws -> URL {
        if let cached = cachedAppPath { return cached }
        let path = try await buildHostApp()
        cachedAppPath = path
        return path
    }

    /// Compile and package the iOS host app.
    private func buildHostApp() async throws -> URL {
        let sourceFile = workDir.appendingPathComponent("PreviewsMCPHost.swift")
        let binaryPath = workDir.appendingPathComponent("PreviewsMCPHost")
        let appDir = workDir.appendingPathComponent("PreviewsMCPHost.app")
        let appBinary = appDir.appendingPathComponent("PreviewsMCPHost")
        let plistPath = appDir.appendingPathComponent("Info.plist")

        // Write source
        try IOSHostAppSource.code.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Compile
        try await run(
            swiftcPath,
            "-emit-executable",
            "-parse-as-library",
            "-target", targetTriple,
            "-sdk", sdkPath,
            "-module-name", "PreviewsMCPHost",
            "-Onone",
            "-o", binaryPath.path,
            sourceFile.path
        )

        // Create .app bundle
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Move binary into .app
        if FileManager.default.fileExists(atPath: appBinary.path) {
            try FileManager.default.removeItem(at: appBinary)
        }
        try FileManager.default.copyItem(at: binaryPath, to: appBinary)

        // Write Info.plist
        try IOSHostAppSource.infoPlist.write(to: plistPath, atomically: true, encoding: .utf8)

        // Copy app icon if available
        if let iconSource = Bundle.module.url(forResource: "AppIcon", withExtension: "png") {
            let iconDest = appDir.appendingPathComponent("AppIcon.png")
            try? FileManager.default.removeItem(at: iconDest)
            try? FileManager.default.copyItem(at: iconSource, to: iconDest)
        }

        // Codesign
        try await run(codesignPath, "-s", "-", "--force", appDir.path)

        return appDir
    }

    // MARK: - Private

    @discardableResult
    private func run(_ args: String...) async throws -> String {
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
            throw IOSHostBuildError.compilationFailed(
                "Command failed: \(args.joined(separator: " "))\n\(stderr)"
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
            throw IOSHostBuildError.compilationFailed(
                "Failed to resolve: \(args.joined(separator: " "))"
            )
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

public enum IOSHostBuildError: Error, LocalizedError, CustomStringConvertible {
    case compilationFailed(String)

    public var description: String {
        switch self {
        case .compilationFailed(let msg): return "iOS host app build failed: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

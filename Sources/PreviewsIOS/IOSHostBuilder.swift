import CryptoKit
import Foundation
import PreviewsCore

/// Compiles the embedded iOS host app source into a signed .app bundle
/// for the iOS simulator.
public actor IOSHostBuilder {
    private let workDir: URL
    private let swiftcPath: String
    private let sdkPath: String
    private let codesignPath: String
    private var cachedAppPath: URL?

    public init(workDir: URL? = nil) async throws {
        let dir =
            workDir
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-host", isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir

        self.sdkPath = try await Self.resolve("xcrun", "--show-sdk-path", "--sdk", "iphonesimulator")
        self.swiftcPath = try await Self.resolve("xcrun", "--find", "swiftc")
        self.codesignPath = try await Self.resolve("xcrun", "--find", "codesign")
    }

    /// Build the iOS host app, returning the path to the .app bundle.
    /// Caches the result — subsequent calls return the cached path.
    /// Rebuilds if the host app source has changed (detected via hash marker).
    public func ensureHostApp() async throws -> URL {
        if let cached = cachedAppPath {
            // Check if source hash still matches
            let hashFile = cached.appendingPathComponent(".source-hash")
            let currentHash = Self.sourceHash
            if let savedHash = try? String(contentsOf: hashFile, encoding: .utf8),
                savedHash == currentHash
            {
                return cached
            }
            // Source changed — invalidate cache and rebuild
            cachedAppPath = nil
        }
        let path = try await buildHostApp()
        cachedAppPath = path
        return path
    }

    /// SHA-256 hash of the host app source, used for cache invalidation.
    private static let sourceHash: String = {
        let data = Data(IOSHostAppSource.code.utf8)
        let digest = SHA256.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }()

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
            "-target", PreviewPlatform.iOS.targetTriple,
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

        // Write source hash for cache invalidation
        let hashFile = appDir.appendingPathComponent(".source-hash")
        try Self.sourceHash.write(to: hashFile, atomically: true, encoding: .utf8)

        return appDir
    }

    // MARK: - Private

    @discardableResult
    private func run(_ args: String...) async throws -> String {
        let output = try await runAsync(args[0], arguments: Array(args.dropFirst()))
        guard output.exitCode == 0 else {
            throw IOSHostBuildError.compilationFailed(
                "Command failed: \(args.joined(separator: " "))\n\(output.stderr)"
            )
        }
        return output.stdout
    }

    private static func resolve(_ args: String...) async throws -> String {
        let output = try await runAsync("/usr/bin/env", arguments: args, discardStderr: true)
        guard output.exitCode == 0 else {
            throw IOSHostBuildError.compilationFailed(
                "Failed to resolve: \(args.joined(separator: " "))"
            )
        }
        return output.stdout
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

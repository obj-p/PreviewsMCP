import CryptoKit
import Foundation
import PreviewsCore

/// Compiles the embedded iOS host app source into a signed .app bundle
/// for the iOS simulator.
public actor IOSHostBuilder {
    private let workDir: URL
    private let swiftcPath: String
    private let clangPath: String
    private let sdkPath: String
    private let codesignPath: String
    private let moduleCachePath: URL
    private var cachedAppPath: URL?
    private var cachedShellAppPath: URL?

    public init(workDir: URL? = nil) async throws {
        let dir =
            workDir
            ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-host", isDirectory: true)

        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        self.workDir = dir

        self.sdkPath = try await Toolchain.sdkPath(for: .iOS)
        self.swiftcPath = try await Toolchain.swiftcPath()
        self.clangPath = try await Toolchain.clangPath()
        self.codesignPath = try await Toolchain.codesignPath()

        let cacheDir = dir.appendingPathComponent("ModuleCache", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        self.moduleCachePath = cacheDir
    }

    /// Build the iOS host app, returning the path to the .app bundle.
    /// Caches the result — subsequent calls return the cached path.
    /// Rebuilds if the host app source has changed (detected via hash marker).
    public func ensureHostApp() async throws -> URL {
        if let fresh = Self.cachedAppIfFresh(cachedAppPath, hash: Self.sourceHash) {
            return fresh
        }
        let path = try await buildHostApp()
        cachedAppPath = path
        return path
    }

    /// Build the foreground shell app that hosts the agent's cross-process
    /// scene, returning the path to the .app bundle. Caches like `ensureHostApp`.
    public func ensureShellApp() async throws -> URL {
        if let fresh = Self.cachedAppIfFresh(cachedShellAppPath, hash: Self.shellSourceHash) {
            return fresh
        }
        let path = try await buildShellApp()
        cachedShellAppPath = path
        return path
    }

    /// Returns the cached .app only if its on-disk `.source-hash` still matches
    /// `hash`; otherwise nil so the caller rebuilds.
    private static func cachedAppIfFresh(_ cached: URL?, hash: String) -> URL? {
        guard let cached else { return nil }
        let hashFile = cached.appendingPathComponent(".source-hash")
        if let savedHash = try? String(contentsOf: hashFile, encoding: .utf8), savedHash == hash {
            return cached
        }
        return nil
    }

    private static func hashHex(_ chunks: [Data]) -> String {
        var hasher = SHA256()
        for chunk in chunks { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// SHA-256 of the shell app source, plist, and entitlements, for cache
    /// invalidation (mirrors `sourceHash` for the host app).
    private static let shellSourceHash: String = hashHex([
        Data(IOSShellAppSource.code.utf8),
        Data(IOSShellAppSource.infoPlist.utf8),
        Data(IOSShellAppSource.entitlements.utf8),
    ])

    /// SHA-256 hash of the host app source, info plist, and embedded
    /// AppIcon.png, used for cache invalidation. Hashing only the Swift
    /// source would miss icon changes — replacing the PNG with a new
    /// design wouldn't rebuild the cached .app.
    private static let sourceHash: String = hashHex([
        Data(IOSHostAppSource.code.utf8),
        Data(IOSHostAppSource.infoPlist.utf8),
        IOSAppIconData.bytes,
    ])

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
        var compileArgs = [
            swiftcPath,
            "-emit-executable",
            "-parse-as-library",
            "-target", PreviewPlatform.iOS.targetTriple,
            "-sdk", sdkPath,
            "-module-name", "PreviewsMCPHost",
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
            "-o", binaryPath.path,
        ]

        // Link the in-app ORC executor so the host can JIT-link objects pushed
        // by the daemon over the second (EPC) socket. server.o references the
        // LLVM symbols, so it must precede the archives; the orc runtime is NOT
        // linked here — the daemon injects it remotely.
        let jit = try Self.jitArtifacts()
        let bridgingHeader = workDir.appendingPathComponent("previewsmcp_ios_executor.h")
        try Self.bridgingHeaderSource.write(to: bridgingHeader, atomically: true, encoding: .utf8)
        compileArgs += [
            "-import-objc-header", bridgingHeader.path,
        ]
        compileArgs.append(sourceFile.path)
        compileArgs.append(jit.serverObject.path)
        compileArgs += [
            "-L", jit.libDir.path,
            "-lLLVMOrcTargetProcess",
            "-lLLVMOrcShared",
            "-lLLVMSupport",
            "-lLLVMTargetParser",
            "-lLLVMDemangle",
            "-lc++",
            // Export the agent's symbols dynamically so the in-app JIT can
            // resolve previewsmcp_set_preview_vc (called by the render entry).
            "-Xlinker", "-export_dynamic",
        ]

        try await run(compileArgs)

        // Create .app bundle
        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)

        // Move binary into .app
        if FileManager.default.fileExists(atPath: appBinary.path) {
            try FileManager.default.removeItem(at: appBinary)
        }
        try FileManager.default.copyItem(at: binaryPath, to: appBinary)

        // Write Info.plist
        try IOSHostAppSource.infoPlist.write(to: plistPath, atomically: true, encoding: .utf8)

        // Write embedded app icon
        let iconDest = appDir.appendingPathComponent("AppIcon.png")
        try IOSAppIconData.bytes.write(to: iconDest)

        // Codesign
        try await run(codesignPath, "-s", "-", "--force", appDir.path)

        // Write source hash for cache invalidation
        let hashFile = appDir.appendingPathComponent(".source-hash")
        try Self.sourceHash.write(to: hashFile, atomically: true, encoding: .utf8)

        return appDir
    }

    /// Compile and package the ObjC shell app.
    private func buildShellApp() async throws -> URL {
        let sourceFile = workDir.appendingPathComponent("PreviewsMCPShell.m")
        let entitlementsFile = workDir.appendingPathComponent("PreviewsMCPShell.entitlements")
        let binaryPath = workDir.appendingPathComponent("PreviewsMCPShell")
        let appDir = workDir.appendingPathComponent("PreviewsMCPShell.app")
        let appBinary = appDir.appendingPathComponent("PreviewsMCPShell")
        let plistPath = appDir.appendingPathComponent("Info.plist")

        try IOSShellAppSource.code.write(to: sourceFile, atomically: true, encoding: .utf8)
        try IOSShellAppSource.entitlements.write(
            to: entitlementsFile, atomically: true, encoding: .utf8)

        // The shell carries restricted RunningBoard entitlements. The simulator
        // honors them only when embedded in the Mach-O (__TEXT,__entitlements)
        // section at link time — a `codesign --entitlements` blob on an ad-hoc
        // signature is rejected with errno 163 for any key.
        let compileArgs = [
            clangPath,
            "-arch", "arm64",
            "-mios-simulator-version-min=17.0",
            "-isysroot", sdkPath,
            "-framework", "UIKit",
            "-framework", "Foundation",
            "-fobjc-arc",
            "-Xlinker", "-sectcreate",
            "-Xlinker", "__TEXT",
            "-Xlinker", "__entitlements",
            "-Xlinker", entitlementsFile.path,
            "-o", binaryPath.path,
            sourceFile.path,
        ]
        try await run(compileArgs)

        try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: appBinary.path) {
            try FileManager.default.removeItem(at: appBinary)
        }
        try FileManager.default.copyItem(at: binaryPath, to: appBinary)
        try IOSShellAppSource.infoPlist.write(to: plistPath, atomically: true, encoding: .utf8)

        // Ad-hoc sign WITHOUT --entitlements (they are section-embedded above).
        try await run(codesignPath, "-s", "-", "--force", appDir.path)

        let hashFile = appDir.appendingPathComponent(".source-hash")
        try Self.shellSourceHash.write(to: hashFile, atomically: true, encoding: .utf8)

        return appDir
    }

    // MARK: - Private

    @discardableResult
    private func run(_ args: String...) async throws -> String {
        try await run(args)
    }

    @discardableResult
    private func run(_ args: [String]) async throws -> String {
        let output = try await runAsync(args[0], arguments: Array(args.dropFirst()))
        guard output.exitCode == 0 else {
            throw IOSHostBuildError.compilationFailed(
                "Command failed: \(args.joined(separator: " "))\n\(output.stderr)"
            )
        }
        return output.stdout
    }

}

extension IOSHostBuilder {
    struct JITArtifacts {
        let serverObject: URL
        let libDir: URL
    }

    /// Locate the iossim JIT executor artifacts staged into PreviewsIOS
    /// resources by the BundleIOSSimJIT plugin. `server.o` and the LLVM
    /// archives share the bundle's resource directory.
    static func jitArtifacts() throws -> JITArtifacts {
        guard let serverObject = Bundle.module.url(forResource: "server", withExtension: "o") else {
            throw IOSHostBuildError.compilationFailed(
                "iOS JIT build requested but server.o is missing from the PreviewsIOS resource bundle"
            )
        }
        return JITArtifacts(
            serverObject: serverObject,
            libDir: serverObject.deletingLastPathComponent()
        )
    }

    static let bridgingHeaderSource = "int previewsmcp_ios_executor_start(int in_fd, int out_fd);\n"

    /// Path to the iossim orc runtime archive the daemon injects remotely via
    /// `JITSession(remoteFD:orcRuntimePath:)`. Not linked into the host app.
    public static var jitOrcRuntimePath: String? {
        Bundle.module.url(forResource: "liborc_rt_iossim", withExtension: "a")?.path
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

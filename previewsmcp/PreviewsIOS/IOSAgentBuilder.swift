import CryptoKit
import Foundation
import PreviewsCore

/// Compiles the embedded iOS agent app source into a signed .app bundle
/// for the iOS simulator.
public actor IOSAgentBuilder {
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
            .appendingPathComponent("previewsmcp-agent", isDirectory: true)

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

    /// Build the iOS agent app, returning the path to the .app bundle.
    /// Caches the result — subsequent calls return the cached path.
    /// Rebuilds if the agent app source has changed (detected via hash marker).
    public func ensureAgentApp() async throws -> URL {
        if let fresh = Self.cachedAppIfFresh(cachedAppPath, hash: Self.sourceHash) {
            return fresh
        }
        let path = try await buildAgentApp()
        cachedAppPath = path
        return path
    }

    /// Build the foreground shell app that hosts the agent's cross-process
    /// scene, returning the path to the .app bundle. Caches like `ensureAgentApp`.
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

    /// SHA-256 of the shell app source, plist, entitlements, and icon, for
    /// cache invalidation (mirrors `sourceHash` for the agent app).
    private static let shellSourceHash: String = hashHex([
        Data(IOSShellAppSource.code.utf8),
        Data(IOSShellAppSource.infoPlist.utf8),
        Data(IOSShellAppSource.entitlements.utf8),
        IOSShellAppSource.iconBytes,
    ])

    /// SHA-256 hash of the agent app source, info plist, and embedded
    /// AppIcon.png, used for cache invalidation. Hashing only the Swift
    /// source would miss icon changes — replacing the PNG with a new
    /// design wouldn't rebuild the cached .app.
    private static let sourceHash: String = hashHex([
        Data(IOSAgentAppSource.code.utf8),
        Data(IOSAgentAppSource.infoPlist.utf8),
        IOSAppIconData.bytes,
    ])

    /// Compile and package the iOS agent app.
    private func buildAgentApp() async throws -> URL {
        let sourceFile = workDir.appendingPathComponent("PreviewsMCPAgent.swift")
        let binaryPath = workDir.appendingPathComponent("PreviewsMCPAgent")
        let appDir = workDir.appendingPathComponent("PreviewsMCPAgent.app")
        let appBinary = appDir.appendingPathComponent("PreviewsMCPAgent")
        let plistPath = appDir.appendingPathComponent("Info.plist")

        // Write source
        try IOSAgentAppSource.code.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Compile
        var compileArgs = [
            swiftcPath,
            "-emit-executable",
            "-parse-as-library",
            "-target", PreviewPlatform.iOS.targetTriple,
            "-sdk", sdkPath,
            "-module-name", "PreviewsMCPAgent",
            "-Onone",
            "-gnone",
            "-module-cache-path", moduleCachePath.path,
            "-o", binaryPath.path,
        ]

        // Link the in-app ORC executor so the agent can JIT-link objects pushed
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
        try IOSAgentAppSource.infoPlist.write(to: plistPath, atomically: true, encoding: .utf8)

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

        let iconDest = appDir.appendingPathComponent("AppIcon.png")
        try IOSShellAppSource.iconBytes.write(to: iconDest)

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
            throw IOSAgentBuildError.compilationFailed(
                "Command failed: \(args.joined(separator: " "))\n\(output.stderr)"
            )
        }
        return output.stdout
    }

}

extension IOSAgentBuilder {
    struct JITArtifacts {
        let serverObject: URL
        let libDir: URL
    }

    /// Bazel staging directory holding server.o, the LLVM TargetProcess
    /// archives, and liborc_rt_iossim.a, resolved from runfiles. nil under
    /// SwiftPM, where the artifacts come from Bundle.module instead.
    static func runfilesJITDir() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let rel = env["PREVIEWSMCP_IOS_JIT_DIR"] {
            if rel.hasPrefix("/") {
                return FileManager.default.fileExists(atPath: rel)
                    ? URL(fileURLWithPath: rel, isDirectory: true) : nil
            }
            for key in ["TEST_SRCDIR", "RUNFILES_DIR"] {
                if let base = env[key] {
                    let candidate = URL(fileURLWithPath: base, isDirectory: true)
                        .appendingPathComponent(rel, isDirectory: true)
                    if FileManager.default.fileExists(atPath: candidate.path) {
                        return candidate
                    }
                }
            }
        }
        return searchRunfilesDir(named: "ios_jit_resources")
    }

    /// Find the resource directory `name` in the binary's runfiles tree, used on
    /// the `bazel run` path where no PREVIEWSMCP_IOS_JIT_DIR env is set. The dir
    /// is a single tree-artifact symlink, so match the entry itself rather than
    /// descending into it.
    private static func searchRunfilesDir(named name: String) -> URL? {
        let env = ProcessInfo.processInfo.environment
        var root: URL?
        for key in ["RUNFILES_DIR", "TEST_SRCDIR"] {
            if let base = env[key], FileManager.default.fileExists(atPath: base) {
                root = URL(fileURLWithPath: base, isDirectory: true)
                break
            }
        }
        if root == nil {
            var candidates: [String] = []
            if let exe = Bundle.main.executableURL?.path {
                candidates.append(exe + ".runfiles")
            }
            if let argv0 = CommandLine.arguments.first {
                candidates.append(argv0 + ".runfiles")
            }
            root = candidates.first { FileManager.default.fileExists(atPath: $0) }
                .map { URL(fileURLWithPath: $0, isDirectory: true) }
        }
        guard let root,
            let enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: nil)
        else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == name {
            return url
        }
        return nil
    }

    /// Locate the iossim JIT executor artifacts (server.o + the LLVM
    /// TargetProcess archives) that share one resource directory.
    static func jitArtifacts() throws -> JITArtifacts {
        if let dir = runfilesJITDir() {
            return JITArtifacts(
                serverObject: dir.appendingPathComponent("server.o"),
                libDir: dir
            )
        }
        guard let serverObject = Bundle.module.url(forResource: "server", withExtension: "o") else {
            throw IOSAgentBuildError.compilationFailed(
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
    /// `JITSession(remoteFD:orcRuntimePath:)`. Not linked into the agent app.
    public static var jitOrcRuntimePath: String? {
        if let dir = runfilesJITDir() {
            return dir.appendingPathComponent("liborc_rt_iossim.a").path
        }
        return Bundle.module.url(forResource: "liborc_rt_iossim", withExtension: "a")?.path
    }
}

public enum IOSAgentBuildError: Error, LocalizedError, CustomStringConvertible {
    case compilationFailed(String)

    public var description: String {
        switch self {
        case .compilationFailed(let msg): return "iOS agent app build failed: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

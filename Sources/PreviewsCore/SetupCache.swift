import CryptoKit
import Foundation
import os

/// Caches `SetupBuilder` results on disk to skip redundant `swift build` invocations
/// when the setup package sources haven't changed.
public enum SetupCache {

    static let cacheDirectory = "previewsmcp-setup-cache"

    // MARK: - Swift Version

    private static let swiftVersionCache = OSAllocatedUnfairLock<String?>(initialState: nil)

    /// Resolve the Swift toolchain version string. Cached for the process lifetime.
    public static func resolveSwiftVersion() async throws -> String {
        if let cached = swiftVersionCache.withLock({ $0 }) { return cached }
        let result = try await runAsync("/usr/bin/env", arguments: ["swift", "--version"])
        guard result.exitCode == 0 else {
            throw SetupCacheError.swiftVersionFailed(result.stderr)
        }
        let version =
            result.stdout.components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces) ?? result.stdout
        swiftVersionCache.withLock { $0 = version }
        return version
    }

    // MARK: - Source Hashing

    /// SHA256 fingerprint of the setup package's Swift sources, lockfile, SDK path,
    /// and Swift toolchain version.
    ///
    /// Inputs hashed (in order):
    /// 1. Sorted `(relativePath, SHA256(fileContents))` for `Package.swift`,
    ///    `Package.resolved` (if present), and every `Sources/**/*.swift`.
    /// 2. The `sdkPath` string (non-nil for iOS builds) so Xcode SDK upgrades
    ///    invalidate the cache.
    /// 3. The `swiftVersion` string so toolchain upgrades invalidate the cache.
    ///
    /// Returns a 64-character lowercase hex string.
    public static func hashSources(
        packageDir: URL, sdkPath: String? = nil, swiftVersion: String? = nil
    ) throws -> String {
        let fm = FileManager.default
        var files: [(relative: String, url: URL)] = []

        // Package.swift (required)
        let packageSwift = packageDir.appendingPathComponent("Package.swift")
        guard fm.fileExists(atPath: packageSwift.path) else {
            throw SetupCacheError.packageNotFound(packageDir.path)
        }
        files.append(("Package.swift", packageSwift))

        // Package.resolved (optional)
        let packageResolved = packageDir.appendingPathComponent("Package.resolved")
        if fm.fileExists(atPath: packageResolved.path) {
            files.append(("Package.resolved", packageResolved))
        }

        // Sources/**/*.swift
        let sourcesDir = packageDir.appendingPathComponent("Sources")
        if let enumerator = fm.enumerator(
            at: sourcesDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            let packageDirPath =
                packageDir.path.hasSuffix("/")
                ? packageDir.path : packageDir.path + "/"
            for case let url as URL in enumerator where url.pathExtension == "swift" {
                let relative = String(url.path.dropFirst(packageDirPath.count))
                files.append((relative, url))
            }
        }

        // Sort by relative path for deterministic ordering
        files.sort { $0.relative < $1.relative }

        // Compute outer hash: each file contributes (relativePath, SHA256(contents))
        var outerHasher = SHA256()
        for (relative, url) in files {
            let data = try Data(contentsOf: url)
            let fileDigest = SHA256.hash(data: data)
            let fileHex = fileDigest.map { String(format: "%02x", $0) }.joined()
            outerHasher.update(data: Data(relative.utf8))
            outerHasher.update(data: Data(fileHex.utf8))
        }

        // Include SDK path so Xcode upgrades invalidate the cache
        if let sdkPath {
            outerHasher.update(data: Data(sdkPath.utf8))
        }

        // Include Swift version so toolchain upgrades invalidate the cache
        if let swiftVersion {
            outerHasher.update(data: Data(swiftVersion.utf8))
        }

        let digest = outerHasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Cache Entry

    struct Entry: Codable, Sendable {
        let moduleName: String
        let typeName: String
        let compilerFlags: [String]
        let dylibPath: String
        let sdkPath: String
        let sourceHash: String
        let swiftVersion: String
        let platform: String
    }

    // MARK: - Load

    /// Look up a cached build result. Returns `nil` on miss, corruption, or when any
    /// artifact referenced by `compilerFlags` no longer exists on disk.
    public static func load(
        packageDir: URL,
        platform: PreviewPlatform,
        sourceHash: String,
        swiftVersion: String
    ) -> SetupBuilder.Result? {
        let file = cacheFile(packageDir: packageDir, platform: platform, sourceHash: sourceHash)
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }

        let data: Data
        do {
            data = try Data(contentsOf: file)
        } catch {
            return nil
        }

        guard let entry = try? JSONDecoder().decode(Entry.self, from: data) else {
            // Corrupt JSON — delete best-effort
            try? FileManager.default.removeItem(at: file)
            return nil
        }

        // Defense-in-depth: verify entry metadata matches even though the filename
        // already encodes platform and sourceHash.
        guard entry.swiftVersion == swiftVersion,
            entry.sourceHash == sourceHash,
            entry.platform == platform.rawValue
        else { return nil }

        guard validateArtifacts(moduleName: entry.moduleName, flags: entry.compilerFlags) else {
            return nil
        }

        let dylibURL = URL(fileURLWithPath: entry.dylibPath)
        guard FileManager.default.fileExists(atPath: dylibURL.path) else { return nil }

        // Issue #170: a cached entry whose SDK has been removed (Xcode upgrade,
        // CommandLineTools change) would otherwise feed a stale path into the
        // downstream Compiler and fail with "SDK not found". Treat as cache miss
        // so SetupBuilder rebuilds and captures the current SDK.
        guard FileManager.default.fileExists(atPath: entry.sdkPath) else { return nil }

        return SetupBuilder.Result(
            moduleName: entry.moduleName,
            typeName: entry.typeName,
            compilerFlags: entry.compilerFlags,
            dylibPath: dylibURL,
            sdkPath: entry.sdkPath
        )
    }

    // MARK: - Store

    /// Persist a build result. Best-effort: failures are logged to stderr, never thrown,
    /// so a broken cache never breaks `preview_start`.
    public static func store(
        _ result: SetupBuilder.Result,
        packageDir: URL,
        platform: PreviewPlatform,
        sourceHash: String,
        swiftVersion: String
    ) {
        do {
            let dir = cacheDir(packageDir: packageDir)
            try FileManager.default.createDirectory(
                at: dir, withIntermediateDirectories: true)

            let entry = Entry(
                moduleName: result.moduleName,
                typeName: result.typeName,
                compilerFlags: result.compilerFlags,
                dylibPath: result.dylibPath.path,
                sdkPath: result.sdkPath,
                sourceHash: sourceHash,
                swiftVersion: swiftVersion,
                platform: platform.rawValue
            )

            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(entry)

            let file = cacheFile(
                packageDir: packageDir, platform: platform, sourceHash: sourceHash)
            try data.write(to: file, options: .atomic)
        } catch {
            fputs(
                "Warning: failed to write setup cache: \(error.localizedDescription)\n", stderr)
        }
    }

    // MARK: - Artifact Validation

    /// Check that every path referenced in `compilerFlags` still exists on disk.
    static func validateArtifacts(moduleName: String, flags: [String]) -> Bool {
        let fm = FileManager.default
        var iDirs: [String] = []
        var lDirs: [String] = []
        var fDirs: [String] = []
        var libs: [String] = []
        var frameworks: [String] = []

        var i = 0
        while i < flags.count {
            let flag = flags[i]
            switch flag {
            case "-I":
                if i + 1 < flags.count { iDirs.append(flags[i + 1]); i += 2 } else { i += 1 }
            case "-L":
                if i + 1 < flags.count { lDirs.append(flags[i + 1]); i += 2 } else { i += 1 }
            case "-F":
                if i + 1 < flags.count { fDirs.append(flags[i + 1]); i += 2 } else { i += 1 }
            case "-framework":
                if i + 1 < flags.count { frameworks.append(flags[i + 1]); i += 2 } else { i += 1 }
            default:
                if flag.hasPrefix("-l") {
                    libs.append(String(flag.dropFirst(2)))
                }
                i += 1
            }
        }

        // Validate -I directories exist and contain a non-empty .swiftmodule
        for dir in iDirs {
            guard fm.fileExists(atPath: dir) else { return false }
            let swiftmodule = (dir as NSString).appendingPathComponent(
                "\(moduleName).swiftmodule")
            guard fm.fileExists(atPath: swiftmodule) else { return false }
            // Ensure the .swiftmodule directory has contents (not left empty by partial clean)
            let contents = try? fm.contentsOfDirectory(atPath: swiftmodule)
            guard let contents, !contents.isEmpty else { return false }
        }

        // Validate -L directories exist
        for dir in lDirs {
            guard fm.fileExists(atPath: dir) else { return false }
        }

        // Validate -l libraries resolve to lib<name>.dylib or lib<name>.a under -L dirs
        for lib in libs {
            let found = lDirs.contains { dir in
                fm.fileExists(
                    atPath: (dir as NSString).appendingPathComponent("lib\(lib).dylib"))
                    || fm.fileExists(
                        atPath: (dir as NSString).appendingPathComponent("lib\(lib).a"))
            }
            guard found else { return false }
        }

        // Validate -F directories exist
        for dir in fDirs {
            guard fm.fileExists(atPath: dir) else { return false }
        }

        // Validate -framework bundles exist under -F dirs
        for fw in frameworks {
            let found = fDirs.contains { dir in
                fm.fileExists(
                    atPath: (dir as NSString).appendingPathComponent("\(fw).framework"))
            }
            guard found else { return false }
        }

        return true
    }

    // MARK: - Paths

    private static func cacheDir(packageDir: URL) -> URL {
        packageDir.appendingPathComponent(".build")
            .appendingPathComponent(cacheDirectory)
    }

    private static func cacheFile(
        packageDir: URL, platform: PreviewPlatform, sourceHash: String
    ) -> URL {
        cacheDir(packageDir: packageDir)
            .appendingPathComponent("\(platform.rawValue.lowercased())-\(sourceHash).json")
    }
}

public enum SetupCacheError: Error, LocalizedError {
    case swiftVersionFailed(String)
    case packageNotFound(String)

    public var errorDescription: String? {
        switch self {
        case .swiftVersionFailed(let stderr):
            return "Failed to resolve Swift version: \(stderr)"
        case .packageNotFound(let path):
            return "Setup package not found at '\(path)'."
        }
    }
}

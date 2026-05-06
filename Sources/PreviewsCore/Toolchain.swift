import Foundation
import os

/// Single source of truth for `xcrun`-based toolchain lookups (SDK paths and
/// tool binary paths). All build-system call sites must go through this
/// helper — hand-rolled `xcrun` calls drift apart over time, and a stale or
/// inconsistent SDK path produces a confusing "cannot load module" error
/// from swiftc downstream (issue #170).
///
/// Results are cached for the process lifetime: xcode-select / DEVELOPER_DIR
/// changes do not propagate to a running daemon, mirroring SPM's own behavior.
public enum Toolchain {

    // MARK: - SDK

    /// Absolute path to the SDK for the given preview platform.
    public static func sdkPath(for platform: PreviewPlatform) async throws -> String {
        switch platform {
        case .macOS: return try await sdkPath(named: "macosx")
        case .iOS: return try await sdkPath(named: "iphonesimulator")
        }
    }

    /// Absolute path to a named SDK (e.g. "macosx", "iphonesimulator").
    public static func sdkPath(named sdk: String) async throws -> String {
        try await cached(key: "sdk:\(sdk)") {
            try await xcrun(["--show-sdk-path", "--sdk", sdk])
        }
    }

    // MARK: - Tools

    /// Absolute path to the active swiftc binary.
    public static func swiftcPath() async throws -> String {
        try await cached(key: "find:swiftc") {
            try await xcrun(["--find", "swiftc"], discardStderr: true)
        }
    }

    /// Absolute path to the active codesign binary.
    public static func codesignPath() async throws -> String {
        try await cached(key: "find:codesign") {
            try await xcrun(["--find", "codesign"], discardStderr: true)
        }
    }

    /// Absolute path to the active ar binary.
    public static func arPath() async throws -> String {
        try await cached(key: "find:ar") {
            try await xcrun(["--find", "ar"], discardStderr: true)
        }
    }

    /// Absolute path to the active xcodebuild binary, or nil if not installed.
    public static func xcodebuildPath() async throws -> String? {
        // Distinct cache key so failures stay observable; we cache success only.
        if let hit = stringCache.withLock({ $0["find:xcodebuild"] }) { return hit }
        let output = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--find", "xcodebuild"], discardStderr: true)
        guard output.exitCode == 0 else { return nil }
        stringCache.withLock { $0["find:xcodebuild"] = output.stdout }
        return output.stdout
    }

    // MARK: - Test hooks

    /// Reset the process-lifetime cache. Tests use this to pick up changes
    /// to xcode-select state between scenarios.
    static func _resetCacheForTesting() {
        stringCache.withLock { $0.removeAll() }
    }

    // MARK: - Private

    private static let stringCache = OSAllocatedUnfairLock<[String: String]>(initialState: [:])

    private static func cached(
        key: String, fetch: () async throws -> String
    ) async throws -> String {
        if let hit = stringCache.withLock({ $0[key] }) { return hit }
        let value = try await fetch()
        stringCache.withLock { $0[key] = value }
        return value
    }

    private static func xcrun(
        _ args: [String], discardStderr: Bool = false
    ) async throws -> String {
        let output = try await runAsync(
            "/usr/bin/xcrun", arguments: args, discardStderr: discardStderr)
        guard output.exitCode == 0 else {
            throw ToolchainError.xcrunFailed(args: args, stderr: output.stderr)
        }
        return output.stdout
    }
}

public enum ToolchainError: Error, LocalizedError, CustomStringConvertible {
    case xcrunFailed(args: [String], stderr: String)

    public var description: String {
        switch self {
        case .xcrunFailed(let args, let stderr):
            let cmd = (["xcrun"] + args).joined(separator: " ")
            let detail = stderr.isEmpty ? "" : ": \(stderr)"
            return "\(cmd) failed\(detail)"
        }
    }

    public var errorDescription: String? { description }
}

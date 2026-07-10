import Foundation
import os
import PreviewsTestSupport

/// Cross-suite serialization for daemon-touching integration tests.
/// Locking mechanics live in `TestFileLock` (TestSupport); this adds the
/// per-run `serve.log` truncation and per-test marker.
enum DaemonTestLock {
    /// Set true the first time any test acquires the lock in this process.
    /// Used to truncate `serve.log` exactly once per `swift test` run so
    /// CI failure dumps stay scoped to the failing run rather than
    /// accumulating across local re-runs. Truncation happens *inside*
    /// the lock to prevent races with other suites running in parallel.
    private static let didTruncateLog = OSAllocatedUnfairLock<Bool>(initialState: false)

    static var effectiveSocketDir: String {
        DaemonTestPaths.effectiveSocketDir
    }

    private static var daemonDirectory: URL {
        URL(fileURLWithPath: effectiveSocketDir, isDirectory: true)
    }

    private static var serveLogPath: URL {
        daemonDirectory.appendingPathComponent("serve.log")
    }

    /// Run `body` while holding the cross-suite daemon lock.
    ///
    /// The `context` (typically `#function`) is written into the daemon's
    /// `serve.log` as a per-test marker so the CI failure dump is greppable
    /// to the failing test's window. Pass a stable, human-readable identifier
    /// — `"\(Self.self).\(#function)"` is a good default.
    static func run<T: Sendable>(
        _ context: String = #function,
        body: @Sendable () async throws -> T
    ) async throws -> T {
        let lock = try await TestFileLock.acquire(DaemonTestPaths.daemonLockPath)
        defer { lock.release() }

        // Inside the lock: prep serve.log so the diagnostic dump on
        // failure has clean, greppable context. Both ops are best-effort
        // — they must never fail the test.
        prepareServeLog(testContext: context)

        return try await body()
    }

    /// Truncate `serve.log` on the first call in this process; always append
    /// a `=== TEST: <ctx> @ <iso8601> ===` marker so the dump can be sliced
    /// to a single test's window.
    private static func prepareServeLog(testContext: String) {
        let logURL = serveLogPath
        let fm = FileManager.default

        // Make sure the parent directory exists; the daemon may not have
        // started yet on the very first test.
        try? fm.createDirectory(
            at: logURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        let shouldTruncate = didTruncateLog.withLock { flag -> Bool in
            if flag { return false }
            flag = true
            return true
        }
        if shouldTruncate, fm.fileExists(atPath: logURL.path) {
            try? Data().write(to: logURL)
        }

        let marker = "=== TEST: \(testContext) @ \(ISO8601DateFormatter().string(from: Date())) ===\n"
        guard let data = marker.data(using: .utf8) else { return }
        if fm.fileExists(atPath: logURL.path) {
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: data)
                try? handle.close()
            }
        } else {
            fm.createFile(atPath: logURL.path, contents: data)
        }
    }
}

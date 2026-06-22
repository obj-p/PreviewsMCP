import Foundation
import os

/// Cross-suite serialization for daemon-touching integration tests.
///
/// Uses a blocking flock on a detached thread to avoid starving
/// Swift's cooperative thread pool. The previous approach (non-
/// blocking flock + Task.sleep polling) caused deadlocks on CI
/// runners with small thread pools: N-1 polling tasks consumed all
/// threads, preventing the lock-holding task's subprocess
/// completion handlers from firing.
enum DaemonTestLock {

    /// Set true the first time any test acquires the lock in this process.
    /// Used to truncate `serve.log` exactly once per `swift test` run so
    /// CI failure dumps stay scoped to the failing run rather than
    /// accumulating across local re-runs. Truncation happens *inside*
    /// the lock to prevent races with other suites running in parallel.
    private static let didTruncateLog = OSAllocatedUnfairLock<Bool>(initialState: false)

    private static var daemonDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp", isDirectory: true)
    }

    private static var serveLogPath: URL {
        daemonDirectory.appendingPathComponent("serve.log")
    }

    private static var lockPath: String {
        let dir =
            ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"]
            ?? FileManager.default.temporaryDirectory.path
        return (dir as NSString).appendingPathComponent("previewsmcp-daemon-test.lock")
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
        // Acquire the lock on a non-cooperative thread so we don't
        // block the Swift concurrency thread pool.
        let path = lockPath
        let fd = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "open(\(path)) failed"
                            ]))
                    return
                }
                // Blocking flock — this thread sleeps in the kernel
                // until the lock is available. Does NOT consume a
                // cooperative thread.
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "flock failed"
                            ]))
                    return
                }
                cont.resume(returning: fd)
            }
        }

        // Inside the lock: prep serve.log so the diagnostic dump on
        // failure has clean, greppable context. Both ops are best-effort
        // — they must never fail the test.
        prepareServeLog(testContext: context)

        let result: Swift.Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }

        _ = flock(fd, LOCK_UN)
        close(fd)
        return try result.get()
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
            withIntermediateDirectories: true)

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

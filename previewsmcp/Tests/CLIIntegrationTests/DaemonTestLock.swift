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

    /// The daemon socket directory the test harness uses, resolved per run.
    ///
    /// Resolution chain (#283): explicit `PREVIEWSMCP_SOCKET_DIR` → a short dir
    /// keyed by `$TEST_TMPDIR` → the system temp dir. Bazel sets `TEST_TMPDIR`
    /// unique per test target and auto-cleans it, so keying the socket dir off
    /// it gives per-target *and* per-run isolation with zero config: a stale
    /// daemon left by a killed prior run can never own the next run's socket.
    /// `CLIRunner` exports this value as `PREVIEWSMCP_SOCKET_DIR` into every
    /// spawned daemon/CLI so production `DaemonPaths` picks it up unchanged
    /// (production must NOT itself honor `TEST_TMPDIR`).
    ///
    /// We do NOT nest the socket under `$TEST_TMPDIR` itself: Bazel's
    /// `$TEST_TMPDIR` lives deep under the execroot (~140 chars) and a Unix
    /// domain socket path is capped at 104 bytes (`sun_path`) on macOS, so
    /// `bind()` would silently fail. Instead we derive a short, stable
    /// `/tmp/pmcp-<hash>` dir from the `$TEST_TMPDIR` string — unique per
    /// target, stable within a run, and comfortably under the limit.
    static var effectiveSocketDir: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PREVIEWSMCP_SOCKET_DIR"] {
            return override
        }
        if let testTmp = env["TEST_TMPDIR"] {
            return "/tmp/pmcp-\(shortHash(testTmp))"
        }
        return FileManager.default.temporaryDirectory.path
    }

    /// Deterministic short hex hash (FNV-1a, 64-bit) of `input`, for building a
    /// short unique socket dir name that stays under the `sun_path` limit.
    private static func shortHash(_ input: String) -> String {
        var hash: UInt64 = 0xCBF2_9CE4_8422_2325
        for byte in input.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01B3
        }
        return String(hash, radix: 16)
    }

    private static var daemonDirectory: URL {
        URL(fileURLWithPath: effectiveSocketDir, isDirectory: true)
    }

    private static var serveLogPath: URL {
        daemonDirectory.appendingPathComponent("serve.log")
    }

    private static var lockPath: String {
        (effectiveSocketDir as NSString).appendingPathComponent("previewsmcp-daemon-test.lock")
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
                    atPath: dir, withIntermediateDirectories: true
                )
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "open(\(path)) failed",
                            ]
                        )
                    )
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
                                    "flock failed",
                            ]
                        )
                    )
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

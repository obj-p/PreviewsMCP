import Foundation

/// Cross-suite serialization for MCP integration tests.
/// See CLIIntegrationTests/DaemonTestLock.swift for rationale.
enum DaemonTestLock {
    @TaskLocal static var socketDir: String?

    /// The daemon socket directory the test harness uses, resolved per run.
    ///
    /// Resolution chain (#283): explicit `PREVIEWSMCP_SOCKET_DIR` → a short dir
    /// keyed by `$TEST_TMPDIR` → the system temp dir. Bazel sets `TEST_TMPDIR`
    /// unique per test target and auto-cleans it, so keying the socket dir off
    /// it gives per-target *and* per-run isolation with zero config: a stale
    /// daemon left by a killed prior run can never own the next run's socket.
    /// The harness exports this value as `PREVIEWSMCP_SOCKET_DIR` into every
    /// spawned daemon so production `DaemonPaths` picks it up unchanged
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

    private static var lockPath: String {
        (effectiveSocketDir as NSString).appendingPathComponent("previewsmcp-daemon-test.lock")
    }

    /// A held exclusive lock. Call `release()` to let the next waiter proceed;
    /// pair it with `defer` at the acquisition site.
    final class Guard: Sendable {
        private let fd: Int32
        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Block until the cross-suite lock is held, then return a `Guard` the
    /// caller releases (via `defer`) when its critical section ends.
    static func acquire() async throws -> Guard {
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
                                NSLocalizedDescriptionKey: "open(\(path)) failed",
                            ]
                        )
                    )
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "flock failed",
                            ]
                        )
                    )
                    return
                }
                cont.resume(returning: fd)
            }
        }
        return Guard(fd: fd)
    }

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        let lock = try await acquire()
        defer { lock.release() }
        return try await body()
    }
}

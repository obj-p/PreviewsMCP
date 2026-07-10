import Foundation

public enum DaemonTestPaths {
    /// The daemon socket directory the test harness uses, resolved per run.
    ///
    /// Resolution chain (#283): explicit `PREVIEWSMCP_SOCKET_DIR` → a short dir
    /// keyed by `$TEST_TMPDIR` → the system temp dir. Bazel sets `TEST_TMPDIR`
    /// unique per test target and auto-cleans it, so keying the socket dir off
    /// it gives per-target *and* per-run isolation with zero config: a stale
    /// daemon left by a killed prior run can never own the next run's socket.
    /// The harness exports this value as `PREVIEWSMCP_SOCKET_DIR` into every
    /// spawned daemon/CLI so production `DaemonPaths` picks it up unchanged
    /// (production must NOT itself honor `TEST_TMPDIR`).
    ///
    /// We do NOT nest the socket under `$TEST_TMPDIR` itself: Bazel's
    /// `$TEST_TMPDIR` lives deep under the execroot (~140 chars) and a Unix
    /// domain socket path is capped at 104 bytes (`sun_path`) on macOS, so
    /// `bind()` would silently fail. Instead we derive a short, stable
    /// `/tmp/pmcp-<hash>` dir from the `$TEST_TMPDIR` string — unique per
    /// target, stable within a run, and comfortably under the limit.
    public static var effectiveSocketDir: String {
        let env = ProcessInfo.processInfo.environment
        if let override = env["PREVIEWSMCP_SOCKET_DIR"] {
            return override
        }
        if let testTmp = env["TEST_TMPDIR"] {
            return "/tmp/pmcp-\(shortHash(testTmp))"
        }
        return FileManager.default.temporaryDirectory.path
    }

    /// The per-run cross-suite daemon lock, shared by both integration
    /// targets' `DaemonTestLock` facades — a single definition so the two
    /// suites can never drift onto different lock files.
    public static var daemonLockPath: String {
        (effectiveSocketDir as NSString).appendingPathComponent("previewsmcp-daemon-test.lock")
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
}

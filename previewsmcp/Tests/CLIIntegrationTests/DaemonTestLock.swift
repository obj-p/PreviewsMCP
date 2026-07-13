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
        // Release ALWAYS — a skipped release from a fence bug would wedge the
        // lock for every later test, far worse than the flake being fixed.
        defer { lock.release() }

        // Inside the lock: prep serve.log so the diagnostic dump on
        // failure has clean, greppable context. Both ops are best-effort
        // — they must never fail the test.
        prepareServeLog(testContext: context)

        // Writer-fence before releasing: a daemon still draining stderr into
        // the shared serve.log when the lock frees byte-races the next
        // locked window's reader (LogsCommandTests etc.). Confirm the daemon
        // is dead — not merely SIGTERM'd — so the next window is clean by
        // construction. Awaited before the return/throw (the non-throwing,
        // bounded fence can't stall the cooperative pool or skip the defer),
        // on both the success and throw paths.
        do {
            let result = try await body()
            await confirmDaemonDead()
            return result
        } catch {
            await confirmDaemonDead()
            throw error
        }
    }

    /// Grace period for a daemon to exit on SIGTERM before the fence
    /// escalates to SIGKILL. Generous so a daemon shutting down under CI
    /// load isn't force-killed spuriously; `kill-daemon`'s 2s give-up was
    /// the original flake source.
    private static let fenceGraceSeconds: TimeInterval = 10

    private static var pidFilePath: URL {
        daemonDirectory.appendingPathComponent("serve.pid")
    }

    /// Guarantee no daemon in this socket dir is still writing serve.log.
    ///
    /// Tests kill their daemon in-block, but some intentionally leave a
    /// detached daemon alive past the block (RunCommand `--detach`), and a
    /// slow shutdown can straggle past a client's give-up. Either way a live
    /// writer must not survive the lock release. Confirm death: SIGTERM,
    /// await actual exit, escalate to SIGKILL if graceful shutdown won't
    /// confirm within the grace window. A test that spawned no daemon finds
    /// no live pid and pays nothing.
    private static func confirmDaemonDead() async {
        guard let pid = readDaemonPID(), isProcessAlive(pid) else { return }
        if await confirmProcessDead(pid, graceSeconds: fenceGraceSeconds) {
            // SIGKILL skipped the daemon's own unregister; drop the stale
            // pidfile so a later fence can't signal a recycled pid.
            try? FileManager.default.removeItem(at: pidFilePath)
        }
    }

    /// SIGTERM `pid`, await its actual exit up to `graceSeconds`, and escalate
    /// to SIGKILL if graceful shutdown won't confirm within the bound. Returns
    /// whether the SIGKILL escalation fired.
    ///
    /// Split from `confirmDaemonDead` (which owns the serve.pid read + stale
    /// pidfile cleanup) so the escalation path has a hermetic test: the test
    /// drives it directly with a short grace against its own throwaway pid —
    /// no daemon lock held, no serve.pid touched — so it can't perturb the
    /// concurrent suite the way a 10s teardown wait or a serve.pid write would.
    static func confirmProcessDead(_ pid: Int32, graceSeconds: TimeInterval) async -> Bool {
        kill(pid, SIGTERM)
        if await awaitProcessDeath(pid, timeout: graceSeconds) { return false }

        // Graceful shutdown didn't confirm within the bound. Surface it —
        // a daemon that won't die on SIGTERM in the grace window is a real
        // shutdown bug worth fixing later, not masking — then force it dead.
        FileHandle.standardError.write(Data(
            """
            DaemonTestLock: pid \(pid) did not exit within \
            \(graceSeconds)s of SIGTERM; escalating to SIGKILL. \
            This is a daemon-shutdown bug worth surfacing — see #397.

            """.utf8
        ))
        kill(pid, SIGKILL)
        _ = await awaitProcessDeath(pid, timeout: 2)
        return true
    }

    /// The daemon pid recorded in this socket dir, or nil if absent/unparseable.
    private static func readDaemonPID() -> Int32? {
        guard
            let contents = try? String(contentsOf: pidFilePath, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    /// `kill(pid, 0)` succeeds iff the process exists and is signalable.
    private static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Poll until `pid` is gone or the timeout elapses. Returns whether the
    /// process is dead at return. `Task.sleep` (not `Thread.sleep`) so the
    /// poll suspends instead of blocking a cooperative thread — a blocking
    /// teardown poll starves the pool and times out concurrent suites.
    private static func awaitProcessDeath(_ pid: Int32, timeout: TimeInterval) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !isProcessAlive(pid) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !isProcessAlive(pid)
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

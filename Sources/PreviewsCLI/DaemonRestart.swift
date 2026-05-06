import Darwin
import Foundation
import MCP

/// Version-mismatch handshake recovery for `DaemonClient`. One of
/// three files extending the `DaemonClient` namespace — see
/// `DaemonClient.swift` for the file-layout overview.
///
/// When a CLI binary connects to a daemon that was spawned by a prior
/// (now-stale) binary — e.g., `brew upgrade` moved `previewsmcp`
/// without touching the running daemon — the MCP `serverInfo.version`
/// in the initialize response won't match the CLI's compile-time
/// version. The connect path in `DaemonClient.connect(...)` detects
/// this, drops the connection, and routes here.
///
/// Implementation:
///   1. Acquire a cross-process `flock` on `DaemonPaths.restartLock`
///      so concurrent CLIs serialize their restart attempts (see #142
///      and `acquireRestartLock` for the `O_CLOEXEC` rationale).
///   2. Re-probe under the lock — a sibling CLI may have already
///      restarted the daemon, in which case we use the fresh one.
///   3. SIGTERM the stale pid and wait for it to exit.
///   4. Spawn a fresh daemon and reconnect; surface a clear error if
///      the new daemon STILL reports a mismatched version (typically
///      a leaked `_PREVIEWSMCP_TEST_DAEMON_VERSION` in the user's env).
///
/// Version comparison rules: see `versionsMatch`.
extension DaemonClient {

    /// Kill the stale daemon and bring up a fresh one matching the
    /// current CLI binary. Serialized across concurrent CLIs via
    /// `flock` on `DaemonPaths.restartLock` so two upgraded CLIs
    /// don't stampede (both SIGTERM, both spawn, one wins the socket
    /// and the other's respawn collides with `ServeCommand`'s
    /// "already running" guard). After acquiring the lock we re-probe
    /// — a sibling CLI may have already fixed the mismatch, in which
    /// case our initial handshake is stale and we should just use
    /// the sibling's fresh daemon. See issue #142.
    static func restartDaemonAndReconnect(
        staleVersion: String,
        currentVersion: String,
        clientName: String,
        startTimeout: TimeInterval,
        configure: ((Client) async -> Void)?
    ) async throws -> Client {
        let lockFd = try await acquireRestartLock()
        defer {
            _ = flock(lockFd, LOCK_UN)
            close(lockFd)
        }

        // A sibling CLI may have restarted the daemon between our
        // mismatch detection and our lock acquisition, making our
        // cached server version stale. Always re-probe under the
        // lock — one extra initialize round-trip, cheap, avoids
        // killing a freshly-spawned daemon. Drop the probe client
        // if it still mismatches; the kill+respawn below needs the
        // socket free of our own connection.
        let (probeClient, probeInit) = try await openClient(
            clientName: clientName, configure: configure)
        if versionsMatch(currentVersion, probeInit.serverInfo.version) {
            return probeClient
        }
        await probeClient.disconnect()

        fputs(
            "previewsmcp: daemon was \(staleVersion), CLI is \(currentVersion) — restarting\n",
            stderr
        )

        if let pid = DaemonLifecycle.readPID() {
            try killDaemonAndWait(pid: pid, timeout: 5.0)
        }

        let reason =
            "prev=\(staleVersion),now=\(currentVersion),"
            + "by=pid\(ProcessInfo.processInfo.processIdentifier)"
        try spawnDaemon(restartReason: reason)
        try await waitForSocket(timeout: startTimeout)

        let (client, initResult) = try await openClient(
            clientName: clientName, configure: configure)
        if !versionsMatch(currentVersion, initResult.serverInfo.version) {
            await client.disconnect()
            throw DaemonClientError.versionStillMismatched(
                reported: initResult.serverInfo.version)
        }
        return client
    }

    /// SIGTERM the given pid and poll until it's gone, or throw on
    /// timeout. Swallows ESRCH — the daemon may have exited on its
    /// own between our read and our signal.
    static func killDaemonAndWait(pid: Int32, timeout: TimeInterval) throws {
        if kill(pid, SIGTERM) != 0 && errno != ESRCH {
            throw DaemonClientError.couldNotSignalDaemon(pid: pid, errno: errno)
        }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !DaemonLifecycle.isProcessAlive(pid) { return }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw DaemonClientError.restartTimedOut(pid: pid)
    }

    /// Acquire the cross-process restart lock. Blocking `flock` runs
    /// on a dispatch-global thread so it doesn't starve Swift's
    /// cooperative pool — same pattern as `DaemonTestLock.run` (see
    /// its comment for context on the starvation we saw before).
    ///
    /// `O_CLOEXEC` is load-bearing: during the respawn we `Process`-
    /// spawn a daemon, which inherits all of our open fds by default.
    /// Without CLOEXEC, the daemon grandchild holds a dup of the
    /// flock fd, so closing our end in `defer` does NOT release the
    /// kernel-level flock — flocks only drop when *every* dup of the
    /// fd is closed. The next CLI then blocks on `flock(LOCK_EX)`
    /// until the daemon dies. CI saw a 50s stall here before this
    /// flag was added. See issue #142.
    static func acquireRestartLock() async throws -> Int32 {
        let path = DaemonPaths.restartLock.path
        return try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                try? DaemonPaths.ensureDirectory()
                let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
                guard fd >= 0 else {
                    cont.resume(throwing: DaemonClientError.lockFailed(errno: errno))
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    let err = errno
                    close(fd)
                    cont.resume(throwing: DaemonClientError.lockFailed(errno: err))
                    return
                }
                cont.resume(returning: fd)
            }
        }
    }

    /// Decide whether two `serverInfo.version` strings are compatible
    /// enough to skip a daemon restart.
    ///
    /// Rules:
    ///   • Both have the git-describe suffix `-<N>-g<SHA>` (both are
    ///     dev builds) — strict equality. Different SHAs can carry
    ///     different protocol-affecting changes, and the whole
    ///     purpose of the handshake is to catch those during
    ///     development iteration.
    ///   • Otherwise — strip the suffix from whichever side has it
    ///     and compare. So `0.12.0` (release) matches `0.12.0-5-gabc`
    ///     (dev build atop that release) without a pointless restart.
    ///
    /// Pre-release tags like `-rc.1` are preserved and compare as
    /// distinct — the regex only matches the numeric-distance-plus-
    /// SHA pattern git-describe produces. See issue #142.
    static func versionsMatch(_ a: String, _ b: String) -> Bool {
        let aHasSuffix = gitDescribeRange(in: a) != nil
        let bHasSuffix = gitDescribeRange(in: b) != nil
        if aHasSuffix && bHasSuffix {
            return a == b
        }
        return baseVersion(a) == baseVersion(b)
    }

    /// Strip the git-describe suffix `-<N>-g<SHA>`, if present.
    static func baseVersion(_ version: String) -> String {
        guard let range = gitDescribeRange(in: version) else { return version }
        return String(version[..<range.lowerBound])
    }

    /// Match `-<N>-g<SHA>$` where SHA is at least 4 hex chars (git's
    /// minimum short-sha length). Narrow on purpose so hand-crafted
    /// strings like `0.12.0-1-gz` don't accidentally match.
    static func gitDescribeRange(in version: String) -> Range<String.Index>? {
        version.range(
            of: "-[0-9]+-g[0-9a-f]{4,}$",
            options: .regularExpression
        )
    }
}

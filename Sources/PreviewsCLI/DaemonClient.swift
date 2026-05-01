import Foundation
import MCP
import Network
import PreviewsCore

/// Client-side handle to the previewsmcp daemon.
///
/// Connects to `~/.previewsmcp/serve.sock`. If no daemon is listening, spawns
/// one (`previewsmcp serve --daemon`) and polls until the socket is ready. The
/// spawned daemon outlives this client.
///
/// ADB-style UX: users don't think about daemon management during normal
/// command flow — first CLI invocation transparently starts it.
enum DaemonClient {

    /// Connect to the daemon, auto-starting it if necessary, and return a
    /// ready-to-use MCP client.
    ///
    /// - Parameters:
    ///   - clientName: MCP client identity reported in the initialize
    ///     handshake (useful in daemon logs).
    ///   - startTimeout: How long to wait for a newly-spawned daemon to become
    ///     reachable on the socket.
    ///   - configure: Optional setup closure that runs *before* the MCP
    ///     initialize handshake, so notification handlers registered here
    ///     will receive all server-emitted notifications including any that
    ///     arrive during or immediately after the handshake. Register any
    ///     `onNotification` handlers here rather than on the returned client
    ///     to avoid dropping early notifications.
    static func connect(
        clientName: String,
        // 60s absorbs combined CI load where the spawned `previewsmcp
        // serve --daemon` child needs to cold-start AppKit, resolve
        // xcrun paths, bind the socket, etc. Observed on PR #141 CI:
        // daemon startup sometimes exceeded 30s while the runner was
        // saturated with parallel test suites. 60s keeps interactive
        // CLI UX fast on the common path (<5s) while still failing
        // fast on a genuine wedged child.
        startTimeout: TimeInterval = 60,
        configure: ((Client) async -> Void)? = nil
    ) async throws -> Client {
        // When no daemon is running we spawn one ourselves. By
        // construction its binary is the one we're currently running
        // (resolved authoritatively via `_NSGetExecutablePath`), so the
        // MCP `serverInfo.version` must equal our own compile-time
        // version — no handshake check needed on this branch.
        let weJustSpawned = !DaemonProbe.canConnect()
        if weJustSpawned {
            try spawnDaemon()
            try await waitForSocket(timeout: startTimeout)
        }

        let (client, initResult) = try await openClient(
            clientName: clientName, configure: configure)

        if weJustSpawned {
            return client
        }

        let serverVersion = initResult.serverInfo.version
        let clientVersion = PreviewsMCPCommand.version
        if versionsMatch(clientVersion, serverVersion) {
            return client
        }

        // Version mismatch: the daemon was spawned by a prior CLI
        // binary that no longer matches ours (e.g., `brew upgrade`
        // moved the binary without touching the running daemon).
        // Drop this connection, take the restart lock, kill the
        // stale daemon, respawn, and reconnect. See issue #142.
        await client.disconnect()
        return try await restartDaemonAndReconnect(
            staleVersion: serverVersion,
            currentVersion: clientVersion,
            clientName: clientName,
            startTimeout: startTimeout,
            configure: configure
        )
    }

    /// Open one MCP connection to the running daemon and return the
    /// initialize response alongside the live client. Factored out of
    /// `connect(...)` so the version-mismatch recovery path can reuse
    /// the same setup (including `configure`) against the respawned
    /// daemon. `configure` runs once per invocation; callers register
    /// notification handlers there rather than on the returned client
    /// to avoid dropping early notifications.
    private static func openClient(
        clientName: String,
        configure: ((Client) async -> Void)?
    ) async throws -> (Client, Initialize.Result) {
        let connection = NWConnection(
            to: NWEndpoint.unix(path: DaemonPaths.socket.path),
            using: .tcp
        )
        let transport = NetworkTransport(connection: connection)
        let client = Client(name: clientName, version: PreviewsMCPCommand.version)
        await configure?(client)
        let initResult = try await client.connect(transport: transport)
        return (client, initResult)
    }

    /// Kill the stale daemon and bring up a fresh one matching the
    /// current CLI binary. Serialized across concurrent CLIs via
    /// `flock` on `DaemonPaths.restartLock` so two upgraded CLIs
    /// don't stampede (both SIGTERM, both spawn, one wins the socket
    /// and the other's respawn collides with `ServeCommand`'s
    /// "already running" guard). After acquiring the lock we re-probe
    /// — a sibling CLI may have already fixed the mismatch, in which
    /// case our initial handshake is stale and we should just use
    /// the sibling's fresh daemon. See issue #142.
    private static func restartDaemonAndReconnect(
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
    private static func killDaemonAndWait(pid: Int32, timeout: TimeInterval) throws {
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
    private static func acquireRestartLock() async throws -> Int32 {
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
    private static func versionsMatch(_ a: String, _ b: String) -> Bool {
        let aHasSuffix = gitDescribeRange(in: a) != nil
        let bHasSuffix = gitDescribeRange(in: b) != nil
        if aHasSuffix && bHasSuffix {
            return a == b
        }
        return baseVersion(a) == baseVersion(b)
    }

    /// Strip the git-describe suffix `-<N>-g<SHA>`, if present.
    private static func baseVersion(_ version: String) -> String {
        guard let range = gitDescribeRange(in: version) else { return version }
        return String(version[..<range.lowerBound])
    }

    /// Match `-<N>-g<SHA>$` where SHA is at least 4 hex chars (git's
    /// minimum short-sha length). Narrow on purpose so hand-crafted
    /// strings like `0.12.0-1-gz` don't accidentally match.
    private static func gitDescribeRange(in version: String) -> Range<String.Index>? {
        version.range(
            of: "-[0-9]+-g[0-9a-f]{4,}$",
            options: .regularExpression
        )
    }

    /// Connect, register the default stderr log-forwarder, run `body`, and
    /// disconnect — regardless of whether the body returns or throws.
    ///
    /// Every CLI subcommand that talks to the daemon needs the same three
    /// things: connect + forward `LogMessageNotification` to stderr +
    /// disconnect on both success and error paths. Skipping any of these
    /// is a subtle footgun (notifications registered after `connect()`
    /// miss handshake-phase messages, a missed `disconnect()` leaks the
    /// transport). This helper enforces the right shape in one place.
    ///
    /// Extra handlers can be registered via `configure`; they run before
    /// the handshake alongside the default log forwarder.
    ///
    /// A `StallTimer` watches the transport for inactivity. Any incoming
    /// notification (log or progress) resets the timer; if `stallThreshold`
    /// elapses with no activity, the client force-disconnects, which
    /// drains pending `callTool` continuations with a transport error
    /// instead of hanging forever. The daemon emits a `logger: "heartbeat"`
    /// ping every 2s (see `runMCPServer`), so a 30s threshold absorbs ~15
    /// missed pings before declaring stall. See issue #135 for the full
    /// context on why this matters (daemon can become non-responsive
    /// after hot-reload; `Client.callTool` has no built-in timeout).
    static func withDaemonClient<T>(
        name: String,
        stallThreshold: Duration = .seconds(30),
        configure: ((Client) async -> Void)? = nil,
        body: (Client) async throws -> T
    ) async throws -> T {
        let timer = StallTimer()

        let client = try await connect(clientName: name) { client in
            await registerStderrLogForwarder(on: client)
            await registerStallBumpers(on: client, timer: timer)
            await configure?(client)
        }

        // Subscribe to `.debug`-level logs so the daemon's heartbeat
        // notifications (emitted at `.debug`) actually reach our bumper.
        // Without this, many MCP clients default to filtering below
        // `.info` and the stall timer would immediately trip because
        // zero heartbeats ever arrive. See the Phase 2 gotchas comment
        // on issue #135 for the full rationale. `try?` tolerates
        // servers that don't advertise logging capability.
        try? await client.setLoggingLevel(.debug)

        // Reset the timer so the window starts now, not at `withDaemonClient`
        // entry. A long `connect()` (e.g., version-mismatch restart that
        // waited on a sibling's lock + spawned a fresh daemon with a slow
        // Compiler init — seen at ~25s on CI) consumes most of the
        // threshold before the watcher even starts, and the first heartbeat
        // (T+2s post-connect) can land right on the stall boundary.
        // Bumping here guarantees the watcher observes a full
        // `stallThreshold` of grace. See issue #142.
        await timer.bump()

        let stallWatcher = Task {
            if await timer.waitForStall(threshold: stallThreshold) {
                // Disconnect drains `pendingRequests` and resumes each
                // waiting continuation with `MCPError.internalError`
                // ("Client disconnected"), per swift-sdk `Client.swift`'s
                // `disconnect()` implementation. The body's `await
                // client.callTool(...)` throws; the caller's catch sees
                // the transport error instead of an infinite wait.
                await client.disconnect()
            }
        }

        do {
            let result = try await body(client)
            stallWatcher.cancel()
            await client.disconnect()
            return result
        } catch {
            stallWatcher.cancel()
            await client.disconnect()
            throw error
        }
    }

    /// Register the MCP LogMessageNotification → stderr bridge that every
    /// CLI command shares. Daemon-side progress messages and warnings
    /// are surfaced as MCP notifications; without this bridge they'd be
    /// silently dropped on the client.
    ///
    /// Silently drops `logger == "heartbeat"` — those are the daemon's
    /// unconditional 2s liveness pings (see `runMCPServer` in
    /// `MCPServer.swift`). They're consumed by the stall timer (see
    /// `registerStallBumpers`) but aren't intended for humans reading
    /// the CLI's stderr.
    private static func registerStderrLogForwarder(on client: Client) async {
        await client.onNotification(LogMessageNotification.self) { message in
            if message.params.logger == "heartbeat" { return }
            if case .string(let text) = message.params.data {
                Log.info(text)
            }
        }
    }

    /// Register handlers that bump `timer` on every incoming MCP
    /// notification. Log messages and progress notifications both count
    /// as "the server is alive and talking to us." Registered in
    /// `withDaemonClient`'s configure closure so handlers are live
    /// before the initialize handshake — early notifications shouldn't
    /// be dropped.
    private static func registerStallBumpers(on client: Client, timer: StallTimer) async {
        await client.onNotification(LogMessageNotification.self) { _ in
            await timer.bump()
        }
        await client.onNotification(ProgressNotification.self) { _ in
            await timer.bump()
        }
    }

    /// Spawn the daemon as an independent child process. We don't wait for it —
    /// the daemon keeps running after this function returns and after the
    /// parent CLI exits.
    ///
    /// `restartReason` is propagated via `_PREVIEWSMCP_DAEMON_RESTART_REASON`
    /// so the new daemon logs a diagnostic breadcrumb to `serve.log` on
    /// startup. Only set when this spawn is a version-mismatch recovery.
    private static func spawnDaemon(restartReason: String? = nil) throws {
        // `_NSGetExecutablePath` returns the kernel's record of the binary
        // we're executing, set at exec() time. Authoritative regardless of
        // CWD, PATH resolution, or what the caller put in argv[0].
        guard let selfPath = resolveRunningBinaryPath() else {
            throw DaemonClientError.binaryNotFound(path: "<unknown>")
        }
        let binaryURL = URL(fileURLWithPath: selfPath)

        // Defense in depth: the binary could have been moved or deleted
        // between resolution and Process.run(). Surface a clear error
        // instead of Process.run()'s generic POSIX failure.
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw DaemonClientError.binaryNotFound(path: binaryURL.path)
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve", "--daemon"]
        // Detach stdio from the client so terminal closure / pipe signals
        // don't affect the daemon. Daemon logs go nowhere for now (future:
        // redirect to ~/.previewsmcp/serve.log).
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        // Route daemon stderr to its log file so startup failures
        // are diagnosable (previously went to /dev/null).
        if let logHandle = try? FileHandle(forWritingTo: DaemonPaths.logFile) {
            logHandle.seekToEndOfFile()
            proc.standardError = logHandle
        } else {
            FileManager.default.createFile(atPath: DaemonPaths.logFile.path, contents: nil)
            proc.standardError =
                (try? FileHandle(forWritingTo: DaemonPaths.logFile)) ?? FileHandle.nullDevice
        }

        // Filter the child env:
        //   • `_PREVIEWSMCP_TEST_DAEMON_VERSION` — integration-test hook
        //     that makes the daemon advertise a fake version. Always
        //     strip it so a stray export in a shell rc can't cause
        //     respawn loops, and so tests that set it on a manual
        //     daemon don't leak it into the respawned daemon's env
        //     (which would re-trip the mismatch path immediately).
        //   • `_PREVIEWSMCP_DAEMON_RESTART_REASON` — opt-in breadcrumb
        //     set only on version-mismatch respawns; clear it on every
        //     other spawn so stale values from a parent CLI don't
        //     masquerade as a restart event.
        var env = ProcessInfo.processInfo.environment
        env["_PREVIEWSMCP_TEST_DAEMON_VERSION"] = nil
        env["_PREVIEWSMCP_DAEMON_RESTART_REASON"] = restartReason
        proc.environment = env

        // Log the resolved binary path on a restart spawn so a user
        // diagnosing a respawn loop can see whether the running binary
        // is still the stale one. No-op for normal startup spawns —
        // the daemon's own "daemon ready (pid ...)" line is enough
        // for those.
        if restartReason != nil {
            fputs(
                "previewsmcp: respawning daemon from \(binaryURL.path)\n",
                stderr
            )
        }

        try proc.run()
    }

    /// Poll the socket until it accepts connections or we give up.
    private static func waitForSocket(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DaemonProbe.canConnect() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonClientError.startupTimedOut
    }
}

enum DaemonClientError: Error, CustomStringConvertible {
    case startupTimedOut
    case binaryNotFound(path: String)
    case couldNotSignalDaemon(pid: Int32, errno: Int32)
    case restartTimedOut(pid: Int32)
    case lockFailed(errno: Int32)
    case versionStillMismatched(reported: String)

    var description: String {
        switch self {
        case .startupTimedOut:
            return "daemon did not become ready on \(DaemonPaths.socket.path)"
        case .binaryNotFound(let path):
            return "previewsmcp binary not found or not executable at \(path)"
        case .couldNotSignalDaemon(let pid, let err):
            let reason = String(cString: strerror(err))
            return "could not signal daemon (pid \(pid)): \(reason)"
        case .restartTimedOut(let pid):
            return
                "stale daemon (pid \(pid)) did not exit within the restart timeout; "
                + "try `previewsmcp kill-daemon` and retry"
        case .lockFailed(let err):
            let reason = String(cString: strerror(err))
            return "could not acquire daemon restart lock: \(reason)"
        case .versionStillMismatched(let reported):
            return
                "daemon still reports version \(reported) after restart; "
                + "check `_PREVIEWSMCP_TEST_DAEMON_VERSION` in your shell environment"
        }
    }
}

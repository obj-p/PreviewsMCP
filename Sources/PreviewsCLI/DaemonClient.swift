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
///
/// The implementation is split across three files:
///
///   • This file (`DaemonClient.swift`) — public entries (`connect`,
///     `withDaemonClient`), `openClient` initialize handshake,
///     daemon spawn + socket-readiness poll.
///   • `DaemonRestart.swift` — version-mismatch detection and the
///     restart-lock-protected kill+respawn path.
///   • `DaemonClientChannel.swift` — notification-handler wiring
///     (stderr log forwarder, stall-timer bumpers).
///
/// All three live as extensions on this `enum DaemonClient` namespace.
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

        // If the daemon was already running but disappears between
        // `canConnect()` and `openClient()`, a sibling CLI almost
        // certainly killed it for a version-mismatch respawn (issue
        // #142). The kill+respawn typically completes in <2s, so
        // wait for the socket to come back and retry the handshake
        // once. Bound at one retry — a second failure means the
        // daemon is genuinely gone, propagate the underlying error.
        // Skip the retry when WE spawned the daemon; in that case a
        // failure is our own startup misbehaving and retrying just
        // hides it.
        let client: Client
        let initResult: Initialize.Result
        do {
            (client, initResult) = try await openClient(
                clientName: clientName, configure: configure)
        } catch {
            guard !weJustSpawned else { throw error }
            try await waitForSocket(timeout: startTimeout)
            (client, initResult) = try await openClient(
                clientName: clientName, configure: configure)
        }

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
        // stale daemon, respawn, and reconnect. See `DaemonRestart`.
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
    /// `connect(...)` so the version-mismatch recovery path
    /// (`restartDaemonAndReconnect`) can reuse the same setup
    /// (including `configure`) against the respawned daemon.
    /// `configure` runs once per invocation; callers register
    /// notification handlers there rather than on the returned client
    /// to avoid dropping early notifications.
    static func openClient(
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

    /// Spawn the daemon as an independent child process. We don't wait for it —
    /// the daemon keeps running after this function returns and after the
    /// parent CLI exits.
    ///
    /// `restartReason` is propagated via `_PREVIEWSMCP_DAEMON_RESTART_REASON`
    /// so the new daemon logs a diagnostic breadcrumb to `serve.log` on
    /// startup. Only set when this spawn is a version-mismatch recovery.
    static func spawnDaemon(restartReason: String? = nil) throws {
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
    static func waitForSocket(timeout: TimeInterval) async throws {
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

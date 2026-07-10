import Foundation
import MCP
import PreviewsCore
import System

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
///     (stderr log forwarder).
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
        configure: ((any MCPClienting) async -> Void)? = nil
    ) async throws -> any MCPClienting {
        // When no daemon is running we spawn one ourselves. By
        // construction its binary is the one we're currently running
        // (resolved authoritatively via `_NSGetExecutablePath`), so the
        // MCP `serverInfo.version` must equal our own compile-time
        // version — no handshake check needed on this branch.
        //
        // Either way the probe's connected socket is kept and handed to
        // `openClient`, so the transport rides the probe connection
        // instead of paying a second connect.
        var probeSocket = DaemonProbe.connect()
        let weJustSpawned = probeSocket == nil
        if weJustSpawned {
            let child = try spawnDaemon()
            probeSocket = try await waitForSocket(timeout: startTimeout, child: child)
        }

        // If the daemon was already running but disappears between
        // `DaemonProbe.connect()` and `openClient()`, a sibling CLI almost
        // certainly killed it for a version-mismatch respawn (issue
        // #142). The kill+respawn typically completes in <2s, so
        // wait for the socket to come back and retry the handshake
        // once. Bound at one retry — a second failure means the
        // daemon is genuinely gone, propagate the underlying error.
        // Skip the retry when WE spawned the daemon; in that case a
        // failure is our own startup misbehaving and retrying just
        // hides it.
        let client: any MCPClienting
        let initResult: Initialize.Result
        do {
            (client, initResult) = try await openClient(
                clientName: clientName, socket: probeSocket, configure: configure
            )
        } catch {
            guard !weJustSpawned else { throw error }
            let socket = try await waitForSocket(timeout: startTimeout)
            (client, initResult) = try await openClient(
                clientName: clientName, socket: socket, configure: configure
            )
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
    ///
    /// Liveness policy (5s interval, 6 missed pongs) bounds wedged-daemon
    /// detection at ~30s — the old StallTimer threshold — independent of
    /// the daemon's own client-liveness cadence. The client starts pinging
    /// at the handshake, inside this call, so daemon spawn or restart time
    /// before it never eats into the window (issue #142) and even a wedged
    /// initialize is bounded. The transport owns the socket: whichever
    /// path disconnects first (body teardown, liveness declaring the
    /// daemon dead, a failed send) closes it after quiescence.
    static func openClient(
        clientName: String,
        socket probeSocket: FileDescriptor? = nil,
        configure: ((any MCPClienting) async -> Void)?
    ) async throws -> (any MCPClienting, Initialize.Result) {
        // A probe-handoff socket (already connected by `DaemonProbe.connect`
        // or `waitForSocket`) is consumed here; otherwise connect fresh.
        let socket = try probeSocket ?? DaemonSocket.connect(to: DaemonPaths.socket.path)
        let transport = FramedTransport(owningSocket: socket)
        let client = PreviewsMCPClient(
            name: clientName, version: PreviewsMCPCommand.version,
            liveness: .init(interval: .seconds(5), missedPongLimit: 6)
        )
        await configure?(client)
        do {
            let initResult = try await client.connect(transport: transport)
            return (client, initResult)
        } catch {
            // A failed handshake must not leak the owned socket; disconnect
            // closes it after quiescence.
            await client.disconnect()
            throw error
        }
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
    /// Wedged-daemon detection is the client's protocol-layer liveness —
    /// policy, timing, and rationale live on `openClient`. Its disconnect
    /// drains pending `callTool` continuations with a transport error
    /// instead of hanging forever (`callTool` has no built-in timeout; a
    /// daemon can wedge after hot-reload, issue #135).
    static func withDaemonClient<T>(
        name: String,
        configure: ((any MCPClienting) async -> Void)? = nil,
        body: (any DaemonToolCalling) async throws -> T
    ) async throws -> T {
        let client = try await connect(clientName: name) { client in
            await registerStderrLogForwarder(on: client)
            await configure?(client)
        }

        do {
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
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
    @discardableResult
    static func spawnDaemon(restartReason: String? = nil) throws -> Process {
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
        return proc
    }

    /// Poll the socket until it accepts connections or we give up. The
    /// winning poll's connected socket is returned (the caller owns it and
    /// hands it to `openClient`), so readiness detection doubles as the
    /// transport's connect.
    ///
    /// When `child` is the daemon process we just spawned, a startup crash
    /// is surfaced immediately as `daemonStartupFailed(exitCode:)` instead
    /// of waiting out the full timeout. The socket check runs first each
    /// iteration so a child that exited only because a sibling won the bind
    /// race still reads as success. See issue #99.
    static func waitForSocket(
        timeout: TimeInterval, child: Process? = nil
    ) async throws -> FileDescriptor {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let socket = DaemonProbe.connect() { return socket }
            if let child, !child.isRunning {
                throw DaemonClientError.daemonStartupFailed(exitCode: child.terminationStatus)
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonClientError.startupTimedOut
    }
}

enum DaemonClientError: Error, Equatable, CustomStringConvertible {
    case startupTimedOut
    case daemonStartupFailed(exitCode: Int32)
    case binaryNotFound(path: String)
    case couldNotSignalDaemon(pid: Int32, errno: Int32)
    case restartTimedOut(pid: Int32)
    case lockFailed(errno: Int32)
    case versionStillMismatched(reported: String)

    var description: String {
        switch self {
        case .startupTimedOut:
            return "daemon did not become ready on \(DaemonPaths.socket.path)"
        case let .daemonStartupFailed(exitCode):
            return
                "daemon exited with status \(exitCode) during startup; "
                    + "see \(DaemonPaths.logFile.path)"
        case let .binaryNotFound(path):
            return "previewsmcp binary not found or not executable at \(path)"
        case let .couldNotSignalDaemon(pid, err):
            let reason = String(cString: strerror(err))
            return "could not signal daemon (pid \(pid)): \(reason)"
        case let .restartTimedOut(pid):
            return
                "stale daemon (pid \(pid)) did not exit within the restart timeout; "
                    + "try `previewsmcp kill-daemon` and retry"
        case let .lockFailed(err):
            let reason = String(cString: strerror(err))
            return "could not acquire daemon restart lock: \(reason)"
        case let .versionStillMismatched(reported):
            return
                "daemon still reports version \(reported) after restart; "
                    + "check `_PREVIEWSMCP_TEST_DAEMON_VERSION` in your shell environment"
        }
    }
}

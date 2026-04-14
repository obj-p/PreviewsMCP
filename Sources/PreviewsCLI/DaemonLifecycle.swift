import Foundation

/// Writes the daemon PID on startup and removes it on graceful shutdown.
/// Installs SIGTERM/SIGINT handlers that trigger cleanup before exiting.
enum DaemonLifecycle {

    /// Detach from the parent's controlling terminal and process group.
    ///
    /// Call this as the *first* step of daemon startup — before the socket
    /// listener binds and starts accepting connections. If setsid() runs
    /// after the socket is live, a client that observes the socket ready
    /// and exits during that window can cascade SIGHUP through the shared
    /// process group and kill the daemon. Doing setsid first eliminates
    /// that race.
    ///
    /// Returns -1 if the process is already a session leader (e.g., when
    /// launched by launchd), which is fine — we're already detached.
    static func detachFromTerminal() {
        _ = Darwin.setsid()
    }

    /// Register this process as the running daemon. Writes `serve.pid` and
    /// installs signal handlers. Call after the socket is listening.
    /// Terminal detachment should have already happened via
    /// `detachFromTerminal()` earlier in startup.
    static func register() throws {
        try DaemonPaths.ensureDirectory()

        let pid = ProcessInfo.processInfo.processIdentifier
        try "\(pid)\n".write(to: DaemonPaths.pidFile, atomically: true, encoding: .utf8)

        installSignalHandlers()
    }

    /// Remove PID file and socket. Safe to call multiple times.
    static func unregister() {
        try? FileManager.default.removeItem(at: DaemonPaths.pidFile)
        try? FileManager.default.removeItem(at: DaemonPaths.socket)
    }

    /// Read the PID from the PID file, if present. Returns nil if missing,
    /// unreadable, or unparseable.
    static func readPID() -> Int32? {
        guard
            let contents = try? String(contentsOf: DaemonPaths.pidFile, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }

    /// Check whether a process with the given PID is alive.
    /// Uses `kill(pid, 0)` which returns success if the process exists and we
    /// have permission to signal it.
    static func isProcessAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Returns the PID of the running daemon, or nil if no daemon is running
    /// *according to the PID file*. Note: the PID file is a management hint,
    /// not a liveness check — a live daemon with a deleted PID file looks
    /// "not running" to this function. Use `DaemonProbe.canConnect()` for
    /// authoritative liveness.
    static func daemonRunningPID() -> Int32? {
        guard let pid = readPID(), isProcessAlive(pid) else { return nil }
        return pid
    }

    private static func installSignalHandlers() {
        // Ignore default Swift signal behavior; handle explicitly.
        signal(SIGTERM, SIG_IGN)
        signal(SIGINT, SIG_IGN)

        let termSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
        termSource.setEventHandler {
            fputs("daemon: received SIGTERM, shutting down\n", stderr)
            unregister()
            Darwin.exit(0)
        }
        termSource.resume()

        let intSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
        intSource.setEventHandler {
            fputs("daemon: received SIGINT, shutting down\n", stderr)
            unregister()
            Darwin.exit(0)
        }
        intSource.resume()

        // Hold strong refs so the sources aren't deallocated.
        retainedSources = [termSource, intSource]
    }

    private nonisolated(unsafe) static var retainedSources: [DispatchSourceSignal] = []
}

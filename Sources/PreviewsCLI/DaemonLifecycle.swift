import Foundation

/// Writes the daemon PID on startup and removes it on graceful shutdown.
/// Installs SIGTERM/SIGINT handlers that trigger cleanup before exiting.
enum DaemonLifecycle {

    /// Register this process as the running daemon. Writes `serve.pid` and
    /// installs signal handlers. Call once during daemon startup, after the
    /// socket is listening.
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

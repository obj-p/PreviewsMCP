import Foundation

/// Filesystem paths for the daemon.
///
/// All daemon state lives under `~/.previewsmcp/` by default. Sessions
/// themselves are held in the daemon's memory (not on disk) — this
/// directory only holds IPC primitives and lifecycle metadata.
///
/// Set `PREVIEWSMCP_SOCKET_DIR` to override the directory. This is used
/// by integration tests to run per-suite daemons on isolated sockets
/// so test suites execute in parallel without a global lock.
enum DaemonPaths {

    /// The daemon state directory. Defaults to `~/.previewsmcp/`;
    /// overridden by the `PREVIEWSMCP_SOCKET_DIR` environment variable.
    static var directory: URL {
        if let override = ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp", isDirectory: true)
    }

    /// Unix domain socket the daemon listens on.
    static var socket: URL {
        directory.appendingPathComponent("serve.sock")
    }

    /// PID file for the running daemon.
    static var pidFile: URL {
        directory.appendingPathComponent("serve.pid")
    }

    /// Log file for daemon stdout/stderr when running detached.
    static var logFile: URL {
        directory.appendingPathComponent("serve.log")
    }

    /// Advisory lock serializing version-mismatch restarts across
    /// concurrent CLI invocations. Held by the client doing the
    /// kill+respawn; the daemon itself never touches it. Kept separate
    /// from `pidFile` (which the daemon owns) so the two concerns don't
    /// race. See issue #142.
    static var restartLock: URL {
        directory.appendingPathComponent("restart.lock")
    }

    /// Cross-process session registry directory. Each running
    /// PreviewsMCP process (stdio MCP server, UDS daemon) writes a
    /// `<pid>.json` file here describing its current session set so
    /// `session_list` from any process can return the union. See
    /// `SessionRegistry`.
    static var sessionsDirectory: URL {
        directory.appendingPathComponent("sessions", isDirectory: true)
    }

    /// Ensure the directory exists with owner-only permissions.
    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

import Foundation

/// Filesystem paths for the daemon.
///
/// All daemon state lives under `~/.previewsmcp/`. Sessions themselves are held
/// in the daemon's memory (not on disk) — this directory only holds IPC
/// primitives and lifecycle metadata.
enum DaemonPaths {

    /// The `~/.previewsmcp/` directory. Created on first use.
    static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp", isDirectory: true)
    }

    /// Unix domain socket the daemon listens on.
    /// Clients connect here to issue MCP JSON-RPC calls.
    static var socket: URL {
        directory.appendingPathComponent("serve.sock")
    }

    /// PID file for the running daemon.
    /// Written on startup, removed on graceful shutdown.
    /// Used by `kill-daemon` and `status` for process targeting and display.
    /// Not used for liveness — that's determined by trying to connect the socket.
    static var pidFile: URL {
        directory.appendingPathComponent("serve.pid")
    }

    /// Log file for daemon stdout/stderr when running detached.
    static var logFile: URL {
        directory.appendingPathComponent("serve.log")
    }

    /// Ensure the directory exists with owner-only permissions. Call
    /// before reading or writing any daemon file. The 0700 mode
    /// restricts the socket (which inherits parent directory
    /// permissions) to the current user on shared-user machines.
    static func ensureDirectory() throws {
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }
}

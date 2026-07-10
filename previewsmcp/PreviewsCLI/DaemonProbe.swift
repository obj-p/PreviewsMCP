import System

/// Liveness check for the daemon: can we connect to its socket?
///
/// This is the canonical "is the daemon running?" test. The kernel atomically
/// tracks socket-to-fd associations, so if `connect()` succeeds, something is
/// listening. A lingering `serve.sock` file from a crashed daemon fails with
/// ECONNREFUSED (and a missing one with ENOENT), so socket file presence
/// alone is not enough.
///
/// Used by:
/// - `ServeCommand --daemon` before unlinking a stale socket, to avoid
///   clobbering a running daemon whose PID file was deleted.
/// - `StatusCommand` for its liveness report.
/// - `DaemonClient` as the auto-start trigger — via `connect()`, which keeps
///   the probe's socket so the MCP transport reuses it instead of paying a
///   second connect.
enum DaemonProbe {
    /// A UDS `connect()` resolves immediately — it either succeeds or fails
    /// with ENOENT/ECONNREFUSED — so no timeout machinery is needed. The
    /// caller owns the returned socket; hand it to
    /// `FramedTransport(owningSocket:)` or close it.
    static func connect() -> FileDescriptor? {
        try? DaemonSocket.connect(to: DaemonPaths.socket.path)
    }

    static func canConnect() -> Bool {
        guard let socket = connect() else { return false }
        try? socket.close()
        return true
    }
}

import MCP
import PreviewsCore

/// Notification-handler wiring for `DaemonClient`. One of three files
/// extending the `DaemonClient` namespace — see `DaemonClient.swift`
/// for the file-layout overview.
///
/// Both helpers run inside `withDaemonClient`'s `configure` closure so they're
/// registered BEFORE the MCP initialize handshake — without that
/// ordering, notifications emitted during the handshake (rare but
/// possible) get dropped on the floor.
///
/// Subtleties documented inline (and in `AGENTS.md:240-241`):
///   • `registerStallBumpers` listens for both log and progress
///     notifications. The daemon emits `logger: "heartbeat"` log
///     notifications every 2s (see `runMCPServer`); without subscribing
///     to `.debug`-level logs in `withDaemonClient`, those heartbeats
///     are filtered before they reach the bumper and the stall timer
///     trips immediately.
///   • `registerStderrLogForwarder` filters out the heartbeat logger
///     so humans reading the CLI's stderr don't see "alive alive
///     alive" spam.
extension DaemonClient {

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
    static func registerStderrLogForwarder(on client: Client) async {
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
    static func registerStallBumpers(on client: Client, timer: StallTimer) async {
        await client.onNotification(LogMessageNotification.self) { _ in
            await timer.bump()
        }
        await client.onNotification(ProgressNotification.self) { _ in
            await timer.bump()
        }
    }
}

import MCP
import PreviewsCore

/// Notification-handler wiring for `DaemonClient`. One of three files
/// extending the `DaemonClient` namespace — see `DaemonClient.swift`
/// for the file-layout overview.
///
/// The helper runs inside `withDaemonClient`'s `configure` closure so it's
/// registered BEFORE the MCP initialize handshake — without that
/// ordering, notifications emitted during the handshake (rare but
/// possible) get dropped on the floor.
extension DaemonClient {
    /// Register the MCP LogMessageNotification → stderr bridge that every
    /// CLI command shares. Daemon-side progress messages and warnings
    /// are surfaced as MCP notifications; without this bridge they'd be
    /// silently dropped on the client.
    ///
    /// Silently drops `logger == "heartbeat"` — a STALE pre-stage-6
    /// daemon emits those every 2s until the version-mismatch restart
    /// replaces it, and they aren't intended for humans reading the
    /// CLI's stderr. Remove the filter only when no pre-stage-6 daemon
    /// can be on the wire.
    static func registerStderrLogForwarder(on client: any MCPClienting) async {
        await client.onNotification(LogMessageNotification.self) { message in
            if message.params.logger == "heartbeat" { return }
            if case let .string(text) = message.params.data {
                Log.info(text)
            }
        }
    }
}

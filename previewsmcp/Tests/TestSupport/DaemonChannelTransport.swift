import MCP
import Network

/// SDK-side transport factory for the interop suites
/// (NetworkTransportHeartbeatTests, DaemonSocketTests,
/// DaemonLifecycleTests) — production traffic rides `FramedTransport`.
/// The rule it encodes binds any test using it: the SDK's transport-level
/// heartbeat is sent unframed and the receive loop discards any read
/// chunk that starts with it, so no peer on this channel may emit
/// transport heartbeats. The SwiftLint daemon_channel_transport_factory
/// rule forces construction through here.
public func daemonChannelTransport(connection: NWConnection) -> NetworkTransport {
    NetworkTransport(connection: connection, heartbeatConfig: .disabled)
}

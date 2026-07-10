import MCP
import Network

/// SDK-side transport factory, TEST-ONLY since the stage-6 cutover:
/// production traffic on the daemon channel rides `FramedTransport`, and
/// this factory survives solely for the SDK-interop suites
/// (NetworkTransportHeartbeatTests, DaemonSocketTests, DaemonLifecycleTests)
/// until stage 7 narrows the SDK dependency. The rule it encodes still
/// binds any test using it: the SDK's transport-level heartbeat is sent
/// unframed and the receive loop discards any read chunk that starts with
/// it, so no peer on this channel may emit transport heartbeats.
public func daemonChannelTransport(connection: NWConnection) -> NetworkTransport {
    NetworkTransport(connection: connection, heartbeatConfig: .disabled)
}

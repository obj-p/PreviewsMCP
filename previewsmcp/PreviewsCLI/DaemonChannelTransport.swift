import MCP
import Network

/// Every transport on the daemon's UDS channel must be built here: the SDK's
/// transport-level heartbeat is sent unframed and the receive loop discards
/// any read chunk that starts with it (see NetworkTransportHeartbeatTests),
/// so no peer on this channel may emit heartbeats.
public func daemonChannelTransport(connection: NWConnection) -> NetworkTransport {
    NetworkTransport(connection: connection, heartbeatConfig: .disabled)
}

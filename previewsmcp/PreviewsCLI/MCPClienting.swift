import MCP

/// The SDK `Client` surface the CLI actually consumes. Both the SDK client
/// and `PreviewsMCPClient` conform, so the client parity suite gates the
/// rewrite differentially and the stage-6 cutover is a construction-site
/// swap. Tool calls come in via `DaemonToolCalling`, the narrower seam CLI
/// command bodies already depend on.
protocol MCPClienting: Actor, DaemonToolCalling {
    @discardableResult
    func onNotification<N: MCP.Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self
    func connect(transport: any Transport) async throws -> Initialize.Result
    func disconnect() async
}

extension Client: MCPClienting {}

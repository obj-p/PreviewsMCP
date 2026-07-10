import MCP

/// The client surface the CLI consumes. `PreviewsMCPClient` conforms in
/// production; the SDK `Client` conforms test-side (see the test target's
/// SDKConformances.swift) so the parity suite gates the rewrite
/// differentially. Tool calls come in via `DaemonToolCalling`, the
/// narrower seam CLI command bodies already depend on.
protocol MCPClienting: Actor, DaemonToolCalling {
    @discardableResult
    func onNotification<N: MCP.Notification>(
        _ type: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) async -> Self
    func connect(transport: any Transport) async throws -> Initialize.Result
    func disconnect() async
}

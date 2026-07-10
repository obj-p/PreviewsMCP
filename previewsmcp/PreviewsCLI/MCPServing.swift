import MCP

/// The server surface the daemon consumes. `PreviewsMCPServer` conforms in
/// production; the SDK `Server` conforms test-side (see the test target's
/// SDKConformances.swift) so the characterization suite gates the rewrite
/// differentially.
protocol MCPServing: Actor {
    @discardableResult
    func withMethodHandler<M: MCP.Method>(
        _ type: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self
    func start(transport: any Transport) async throws
    func stop() async
    func waitUntilCompleted() async
    func notify(_ notification: Message<some MCP.Notification>) async throws
    func log(level: LogLevel, logger: String?, data: Value) async throws
}

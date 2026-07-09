import MCP

/// The SDK `Server` surface the daemon and the stage-1 characterization
/// suite actually consume. Both the SDK server and `PreviewsMCPServer`
/// conform, so the suite gates the rewrite differentially and the stage-5
/// cutover is a construction-site swap.
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

extension Server: MCPServing {
    func start(transport: any Transport) async throws {
        try await start(transport: transport, initializeHook: nil)
    }
}

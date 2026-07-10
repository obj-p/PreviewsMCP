import MCP
@testable import PreviewsCLI

/// SDK-side seam conformances, test-only since stage 7: production runs
/// `PreviewsMCPServer`/`PreviewsMCPClient` exclusively, and the SDK
/// `Server`/`Client` stay wired only as the characterization suites'
/// differential arms (`ServerKind.sdk` / `ClientKind.sdk`) and
/// `MCPTestServer`'s permanent independent-implementation cross-check.
extension Server: @retroactive MCPServing {
    public func start(transport: any Transport) async throws {
        try await start(transport: transport, initializeHook: nil)
    }
}

extension Client: @retroactive MCPClienting {}

extension Client: @retroactive DaemonToolCalling {
    /// Call an MCP tool and return the full `CallTool.Result` including
    /// `structuredContent`. The SDK's primary `callTool(name:arguments:)`
    /// overload drops that field.
    public func callToolStructured(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        let context: RequestContext<CallTool.Result> = try callTool(
            name: name, arguments: arguments
        )
        return try await context.value
    }
}

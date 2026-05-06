import MCP

/// One MCP tool. Each conformer owns its name, JSON Schema, and handler
/// in a single file under `Sources/PreviewsCLI/Handlers/`.
///
/// `ToolName`, the schema, and the dispatch switch in
/// `configureMCPServer` previously had to be kept in lockstep across
/// three places. The handler registry derives `ListTools` and the
/// `CallTool` dispatch from the array of `ToolHandler.Type` values, so
/// adding a tool now means adding one file plus one line in the
/// registry.
protocol ToolHandler: Sendable {
    /// MCP tool name as exposed on the wire.
    static var name: ToolName { get }

    /// JSON Schema for the tool's parameters. Sent verbatim in
    /// `ListTools` responses; the byte stability of this value is
    /// pinned by `ListToolsSnapshotTests`.
    static var schema: Tool { get }

    /// Run the tool against the provided parameters. Errors thrown
    /// here propagate to the MCP client as call failures; recoverable
    /// validation errors should return `CallTool.Result(isError: true)`
    /// with a text message instead.
    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result
}

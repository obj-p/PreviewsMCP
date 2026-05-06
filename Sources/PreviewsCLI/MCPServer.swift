import MCP
import PreviewsCore
import PreviewsEngine
import PreviewsMacOS

/// Every MCP tool the daemon exposes. Order is preserved in `ListTools`
/// responses; the `ListToolsSnapshotTests` byte-snapshot pins this order
/// alongside the schema bytes.
///
/// To add a tool: write a new file in `Handlers/`, conform it to
/// `ToolHandler`, and append the type below. There is intentionally no
/// indirect registration mechanism — the array IS the inventory.
let handlerRegistry: [any ToolHandler.Type] = [
    PreviewListHandler.self,
    PreviewStartHandler.self,
    PreviewSnapshotHandler.self,
    PreviewStopHandler.self,
    PreviewConfigureHandler.self,
    PreviewSwitchHandler.self,
    PreviewElementsHandler.self,
    PreviewTouchHandler.self,
    PreviewVariantsHandler.self,
    SimulatorListHandler.self,
    SessionListHandler.self,
    PreviewBuildInfoHandler.self,
]

/// All MCP tool schemas exposed by the daemon, derived from the registry.
/// Pinned by `ListToolsSnapshotTests` so a future refactor can't silently
/// change the on-the-wire shape.
func mcpToolSchemas() -> [Tool] {
    handlerRegistry.map { $0.schema }
}

/// Configures and returns an MCP server with preview tools.
///
/// - Parameter sharedCompiler: Pass a pre-built `Compiler` to reuse across
///   multiple server instances (e.g., daemon mode, where each accepted client
///   connection gets its own `Server` but they all share one compiler). When
///   nil, a fresh compiler is built — appropriate for single-connection modes
///   like stdio.
func configureMCPServer(
    host previewHost: PreviewHost,
    iosManager: IOSSessionManager,
    configCache cache: ConfigCache,
    sharedCompiler: Compiler? = nil
) async throws -> (Server, Compiler) {
    cleanupStaleTempDirs()

    let compiler: Compiler
    if let sharedCompiler {
        compiler = sharedCompiler
    } else {
        compiler = try await Compiler()
    }

    let server = Server(
        name: "previewsmcp",
        version: advertisedServerVersion(),
        capabilities: .init(logging: .init(), tools: .init(listChanged: false))
    )

    let router = SessionRouter(host: previewHost, iosManager: iosManager)
    let ctx = HandlerContext(
        host: previewHost,
        iosState: iosManager,
        configCache: cache,
        router: router,
        macCompiler: compiler,
        server: server
    )

    // Index handlers by wire name once so dispatch is O(1) rather than
    // a linear scan of the registry per call.
    let handlersByName: [String: any ToolHandler.Type] = Dictionary(
        uniqueKeysWithValues: handlerRegistry.map { ($0.name.rawValue, $0) }
    )

    await server.withMethodHandler(ListTools.self) { _ in
        ListTools.Result(tools: mcpToolSchemas())
    }

    await server.withMethodHandler(CallTool.self) { params in
        Log.info("mcp: callTool \(params.name)")
        guard let handler = handlersByName[params.name] else {
            return CallTool.Result(content: [.text("Unknown tool: \(params.name)")], isError: true)
        }
        return try await handler.handle(params, ctx: ctx)
    }

    return (server, compiler)
}

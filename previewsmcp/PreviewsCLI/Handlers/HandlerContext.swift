import MCP
import PreviewsCore
import PreviewsEngine
import PreviewsMacOS

/// Engine-layer dependencies bundled for a single MCP tool invocation.
/// Constructed once per `configureMCPServer` call and passed to every
/// `ToolHandler.handle(_:ctx:)`.
///
/// All members are `Sendable`: `PreviewHost` is `@MainActor`-isolated,
/// every other member is an actor, and `Compiler` is an actor as well.
/// Crossing isolation domains is the caller's responsibility.
struct HandlerContext: Sendable {
    let host: PreviewHost
    let iosState: IOSSessionManager
    let configCache: ConfigCache
    let router: SessionRouter
    let registry: SessionRegistry
    let macCompiler: Compiler
    let server: Server
}

import Foundation
import MCP
import Network
import PreviewsCore
import PreviewsEngine
import PreviewsMacOS

/// Runs the MCP server daemon on a Unix domain socket.
///
/// Accepts multiple concurrent client connections. Each connection gets its own
/// `MCP.Server` instance, but all connections share a single
/// `IOSSessionManager`, `ConfigCache`, and `Compiler` created at daemon
/// startup — so preview sessions persist across CLI invocations and
/// simultaneous clients see consistent state.
enum DaemonListener {

    /// Start the daemon listener. Returns once the listener is ready to accept
    /// connections. Callers hold the process alive via the existing
    /// `NSApplication` run loop (see `PreviewsMCPApp.main`).
    static func start(host: PreviewHost) async throws -> NWListener {
        try DaemonPaths.ensureDirectory()

        // Clean up any stale socket file from a previous crashed daemon.
        // bind() would fail with EADDRINUSE otherwise. Callers must have
        // already verified via DaemonProbe that no live daemon is listening.
        try? FileManager.default.removeItem(at: DaemonPaths.socket)

        // Build shared resources once. Each accepted connection creates its
        // own MCP.Server but reuses these instances, avoiding per-connection
        // xcrun / SDK resolution cost and ensuring sessions persist across
        // CLI invocations.
        let sharedCompiler = try await Compiler()
        let iosManager = IOSSessionManager()
        let configCache = ConfigCache()
        // Cross-process session registry. Constructed once and attached
        // here (not per-connection) so the publish-on-mutation hooks on
        // the iOS manager and macOS host are wired exactly once. See
        // architectural plan #6b.
        let registry = SessionRegistry(registryDir: DaemonPaths.sessionsDirectory)
        await registry.attachTo(iosManager: iosManager, previewHost: host)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: DaemonPaths.socket.path)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { connection in
            Task {
                await handleConnection(
                    connection, compiler: sharedCompiler,
                    host: host, iosManager: iosManager, configCache: configCache,
                    registry: registry
                )
            }
        }

        // Block until the listener reports ready (or fails).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    Log.info("previewsmcp daemon listening on \(DaemonPaths.socket.path)")
                    cont.resume()
                    // Clear after resuming so the closure isn't retained.
                    listener.stateUpdateHandler = nil
                case .failed(let error):
                    cont.resume(throwing: error)
                    listener.stateUpdateHandler = nil
                default:
                    break
                }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        return listener
    }

    /// Handle one client connection. Creates a per-connection MCP Server
    /// sharing the given compiler and module-level state with other connections.
    private static func handleConnection(
        _ connection: NWConnection, compiler: Compiler,
        host: PreviewHost, iosManager: IOSSessionManager, configCache: ConfigCache,
        registry: SessionRegistry
    ) async {
        do {
            let transport = NetworkTransport(connection: connection)
            let (server, _) = try await configureMCPServer(
                host: host, iosManager: iosManager,
                configCache: configCache, registry: registry,
                sharedCompiler: compiler
            )
            try await runMCPServer(server, transport: transport)
            // `runMCPServer` returns when the transport closes (client disconnected).
        } catch {
            Log.error("daemon connection error: \(error)")
            connection.cancel()
        }
    }
}

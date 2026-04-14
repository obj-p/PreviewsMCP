import Foundation
import MCP
import Network

/// Runs the MCP server daemon on a Unix domain socket.
///
/// Accepts multiple concurrent client connections. Each connection gets its own
/// `MCP.Server` instance, but all connections share the module-level actors in
/// `MCPServer.swift` (`IOSState`, `ConfigCache`) — so preview sessions persist
/// across CLI invocations and simultaneous clients see consistent state.
enum DaemonListener {

    /// Start the daemon listener. Returns when the listener is ready.
    /// Call `runForever` to block the caller until the process is terminated.
    @MainActor
    static func start() async throws -> NWListener {
        try DaemonPaths.ensureDirectory()

        // Clean up any stale socket file from a previous crashed daemon.
        // bind() would fail with EADDRINUSE otherwise.
        try? FileManager.default.removeItem(at: DaemonPaths.socket)

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: DaemonPaths.socket.path)
        // Allow multiple clients; each is handled in its own Task.
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)

        listener.stateUpdateHandler = { state in
            switch state {
            case .ready:
                fputs("previewsmcp daemon listening on \(DaemonPaths.socket.path)\n", stderr)
            case .failed(let error):
                fputs("previewsmcp daemon listener failed: \(error)\n", stderr)
                Darwin.exit(1)
            default:
                break
            }
        }

        listener.newConnectionHandler = { connection in
            Task {
                await handleConnection(connection)
            }
        }

        // Wait for listener to become ready before returning.
        let ready = AsyncStream<Void> { continuation in
            let original = listener.stateUpdateHandler
            listener.stateUpdateHandler = { state in
                original?(state)
                if case .ready = state { continuation.yield(); continuation.finish() }
                if case .failed = state { continuation.finish() }
            }
        }

        listener.start(queue: .global(qos: .userInitiated))
        for await _ in ready { break }

        return listener
    }

    /// Block the calling thread indefinitely. Used after the daemon is set up
    /// to keep the NSApplication run loop alive for accepting connections.
    static func runForever() {
        dispatchMain()
    }

    /// Handle one client connection. Creates a per-connection MCP Server
    /// sharing module-level state with other connections.
    private static func handleConnection(_ connection: NWConnection) async {
        do {
            let transport = NetworkTransport(connection: connection)
            let (server, _) = try await configureMCPServer()
            try await server.start(transport: transport)
            // `start` returns when the transport closes (client disconnected).
        } catch {
            fputs("daemon connection error: \(error)\n", stderr)
            connection.cancel()
        }
    }
}

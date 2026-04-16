import Foundation
import MCP
import Network
import PreviewsCore
import PreviewsMacOS

/// Runs the MCP server daemon on a Unix domain socket.
///
/// Accepts multiple concurrent client connections. Each connection gets its own
/// `MCP.Server` instance, but all connections share the module-level actors in
/// `MCPServer.swift` (`IOSState`, `ConfigCache`) and a single `Compiler` built
/// at daemon startup — so preview sessions persist across CLI invocations and
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

        // Build the shared compiler once. Each accepted connection creates its
        // own MCP.Server but reuses this compiler (and the module-level
        // IOSState / ConfigCache), avoiding the ~seconds of per-connection
        // xcrun / SDK resolution cost.
        let sharedCompiler = try await Compiler()

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: DaemonPaths.socket.path)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)

        listener.newConnectionHandler = { connection in
            Task {
                await handleConnection(connection, compiler: sharedCompiler, host: host)
            }
        }

        // Block until the listener reports ready (or fails).
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    fputs(
                        "previewsmcp daemon listening on \(DaemonPaths.socket.path)\n",
                        stderr
                    )
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
        _ connection: NWConnection, compiler: Compiler, host: PreviewHost
    ) async {
        do {
            let transport = NetworkTransport(connection: connection)
            let (server, _) = try await configureMCPServer(host: host, sharedCompiler: compiler)
            try await server.start(transport: transport)
            // `start` returns when the transport closes (client disconnected).
        } catch {
            fputs("daemon connection error: \(error)\n", stderr)
            connection.cancel()
        }
    }
}

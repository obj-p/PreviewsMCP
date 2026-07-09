import Foundation
import PreviewsCore
import PreviewsEngine
import PreviewsMacOS
import System

/// Runs the MCP server daemon on a Unix domain socket.
///
/// Accepts multiple concurrent client connections. Each connection gets its
/// own `PreviewsMCPServer` instance, but all connections share a single
/// `IOSSessionManager`, `ConfigCache`, and `Compiler` created at daemon
/// startup — so preview sessions persist across CLI invocations and
/// simultaneous clients see consistent state.
enum DaemonListener {
    /// Start the daemon listener. Readiness is `DaemonSocket.listen`
    /// returning — the kernel queues connections from that moment — so this
    /// returns with the socket accepting and the accept loop running in a
    /// task that lives for the rest of the process. Callers hold the
    /// process alive via the existing `NSApplication` run loop (see
    /// `PreviewsMCPApp.main`).
    static func start(host: PreviewHost) async throws {
        try DaemonPaths.ensureDirectory()

        // Clean up any stale socket file from a previous crashed daemon.
        // bind() would fail with EADDRINUSE otherwise. Callers must have
        // already verified via DaemonProbe that no live daemon is listening.
        try? FileManager.default.removeItem(at: DaemonPaths.socket)

        // Build shared resources once. Each accepted connection creates its
        // own server but reuses these instances, avoiding per-connection
        // xcrun / SDK resolution cost and ensuring sessions persist across
        // CLI invocations.
        let compiler = try await Compiler()
        let iosManager = IOSSessionManager()
        let configCache = ConfigCache()
        // Cross-process session registry. Constructed once and attached
        // here (not per-connection) so the publish-on-mutation hooks on
        // the iOS manager and macOS host are wired exactly once. See
        // architectural plan #6b.
        let registry = SessionRegistry(registryDir: DaemonPaths.sessionsDirectory)
        await registry.attachTo(iosManager: iosManager, previewHost: host)

        let listener = try DaemonSocket.listen(at: DaemonPaths.socket.path)
        Log.info("previewsmcp daemon listening on \(DaemonPaths.socket.path)")

        // Accept for the life of the process, one handler task per
        // connection. A non-retryable accept failure is fail-stop: the loop
        // exits and closes the listener, existing connections keep serving,
        // and new probes get ECONNREFUSED so the client-side auto-restart
        // path takes over.
        Task {
            defer { try? listener.close() }
            while true {
                let connection: FileDescriptor
                do {
                    connection = try await DaemonSocket.accept(on: listener)
                } catch {
                    Log.error("daemon accept failed: \(error)")
                    return
                }
                Task {
                    await handleConnection(
                        connection, compiler: compiler, host: host,
                        iosManager: iosManager, configCache: configCache,
                        registry: registry
                    )
                }
            }
        }
    }

    /// Handle one client connection: serve MCP until the peer disconnects,
    /// then disconnect the transport and close the descriptor, in that
    /// order. In-flight handlers run to completion after the close (their
    /// responses drop); sessions persist across connections, so a finishing
    /// render warms the next one.
    private static func handleConnection(
        _ connection: FileDescriptor, compiler: Compiler, host: PreviewHost,
        iosManager: IOSSessionManager, configCache: ConfigCache,
        registry: SessionRegistry
    ) async {
        let transport = FramedTransport(socket: connection)
        do {
            let (server, _) = try await configureMCPServer(
                host: host, iosManager: iosManager,
                configCache: configCache, registry: registry,
                sharedCompiler: compiler, liveness: .init()
            )
            try await runMCPServer(server, transport: transport)
            // `runMCPServer` returns when the transport closes (client disconnected).
        } catch {
            Log.error("daemon connection error: \(error)")
        }
        await transport.disconnect()
        try? connection.close()
    }
}

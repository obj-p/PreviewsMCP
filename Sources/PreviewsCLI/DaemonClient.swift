import Foundation
import MCP
import Network

/// Client-side handle to the previewsmcp daemon.
///
/// Connects to `~/.previewsmcp/serve.sock`. If no daemon is listening, spawns
/// one (`previewsmcp serve --daemon`) and polls until the socket is ready. The
/// spawned daemon outlives this client.
///
/// ADB-style UX: users don't think about daemon management during normal
/// command flow — first CLI invocation transparently starts it.
enum DaemonClient {

    /// Connect to the daemon, auto-starting it if necessary, and return a
    /// ready-to-use MCP client.
    ///
    /// - Parameters:
    ///   - clientName: MCP client identity reported in the initialize
    ///     handshake (useful in daemon logs).
    ///   - startTimeout: How long to wait for a newly-spawned daemon to become
    ///     reachable on the socket.
    ///   - configure: Optional setup closure that runs *before* the MCP
    ///     initialize handshake, so notification handlers registered here
    ///     will receive all server-emitted notifications including any that
    ///     arrive during or immediately after the handshake. Register any
    ///     `onNotification` handlers here rather than on the returned client
    ///     to avoid dropping early notifications.
    static func connect(
        clientName: String,
        startTimeout: TimeInterval = 30,
        configure: ((Client) async -> Void)? = nil
    ) async throws -> Client {
        if !DaemonProbe.canConnect() {
            try spawnDaemon()
            try await waitForSocket(timeout: startTimeout)
        }

        let connection = NWConnection(
            to: NWEndpoint.unix(path: DaemonPaths.socket.path),
            using: .tcp
        )
        let transport = NetworkTransport(connection: connection)
        let client = Client(name: clientName, version: PreviewsMCPCommand.version)
        await configure?(client)
        _ = try await client.connect(transport: transport)
        return client
    }

    /// Connect, register the default stderr log-forwarder, run `body`, and
    /// disconnect — regardless of whether the body returns or throws.
    ///
    /// Every CLI subcommand that talks to the daemon needs the same three
    /// things: connect + forward `LogMessageNotification` to stderr +
    /// disconnect on both success and error paths. Skipping any of these
    /// is a subtle footgun (notifications registered after `connect()`
    /// miss handshake-phase messages, a missed `disconnect()` leaks the
    /// transport). This helper enforces the right shape in one place.
    ///
    /// Extra handlers can be registered via `configure`; they run before
    /// the handshake alongside the default log forwarder.
    static func withDaemonClient<T>(
        name: String,
        configure: ((Client) async -> Void)? = nil,
        body: (Client) async throws -> T
    ) async throws -> T {
        let client = try await connect(clientName: name) { client in
            await registerStderrLogForwarder(on: client)
            await configure?(client)
        }
        do {
            let result = try await body(client)
            await client.disconnect()
            return result
        } catch {
            await client.disconnect()
            throw error
        }
    }

    /// Register the MCP LogMessageNotification → stderr bridge that every
    /// CLI command shares. Daemon-side progress messages and warnings
    /// are surfaced as MCP notifications; without this bridge they'd be
    /// silently dropped on the client.
    private static func registerStderrLogForwarder(on client: Client) async {
        await client.onNotification(LogMessageNotification.self) { message in
            if case .string(let text) = message.params.data {
                fputs("\(text)\n", stderr)
            }
        }
    }

    /// Spawn the daemon as an independent child process. We don't wait for it —
    /// the daemon keeps running after this function returns and after the
    /// parent CLI exits.
    private static func spawnDaemon() throws {
        let selfPath = ProcessInfo.processInfo.arguments[0]
        let binaryURL = URL(fileURLWithPath: selfPath).standardizedFileURL

        // Best-effort sanity check so a missing binary surfaces as a clear
        // error instead of Process.run()'s generic POSIX failure. This is
        // not a security boundary — a spoofed argv[0] pointing at some
        // other real executable would still pass this check. See #100 for
        // authoritative self-path resolution via _NSGetExecutablePath.
        guard FileManager.default.isExecutableFile(atPath: binaryURL.path) else {
            throw DaemonClientError.binaryNotFound(path: binaryURL.path)
        }

        let proc = Process()
        proc.executableURL = binaryURL
        proc.arguments = ["serve", "--daemon"]
        // Detach stdio from the client so terminal closure / pipe signals
        // don't affect the daemon. Daemon logs go nowhere for now (future:
        // redirect to ~/.previewsmcp/serve.log).
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        // Route daemon stderr to its log file so startup failures
        // are diagnosable (previously went to /dev/null).
        if let logHandle = try? FileHandle(forWritingTo: DaemonPaths.logFile) {
            logHandle.seekToEndOfFile()
            proc.standardError = logHandle
        } else {
            FileManager.default.createFile(atPath: DaemonPaths.logFile.path, contents: nil)
            proc.standardError =
                (try? FileHandle(forWritingTo: DaemonPaths.logFile)) ?? FileHandle.nullDevice
        }
        try proc.run()
    }

    /// Poll the socket until it accepts connections or we give up.
    private static func waitForSocket(timeout: TimeInterval) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if DaemonProbe.canConnect() { return }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw DaemonClientError.startupTimedOut
    }
}

enum DaemonClientError: Error, CustomStringConvertible {
    case startupTimedOut
    case binaryNotFound(path: String)

    var description: String {
        switch self {
        case .startupTimedOut:
            return "daemon did not become ready on \(DaemonPaths.socket.path)"
        case .binaryNotFound(let path):
            return "previewsmcp binary not found or not executable at \(path)"
        }
    }
}

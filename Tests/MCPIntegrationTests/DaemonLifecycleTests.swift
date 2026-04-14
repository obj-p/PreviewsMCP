import Foundation
import MCP
import Network
import Testing

/// Integration tests for `previewsmcp serve --daemon` / `status` / `kill-daemon`.
///
/// These tests spawn the real `previewsmcp` binary and speak MCP over the Unix
/// domain socket. They assume no other daemon is running — each test cleans up
/// after itself, and the suite is serialized so they don't race.
@Suite(.serialized)
struct DaemonLifecycleTests {

    // MARK: - Paths

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static let binaryPath: String =
        repoRoot.appendingPathComponent(".build/debug/previewsmcp").path

    static let socketPath: String =
        FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".previewsmcp/serve.sock").path

    // MARK: - Test helpers

    /// Remove any daemon state from previous runs and kill any running daemon.
    private static func cleanSlate() async throws {
        // Best-effort kill. Ignore errors — daemon may not be running.
        _ = try? await runCLI(["kill-daemon", "--timeout", "2"])
        // Remove any leftover files.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
    }

    /// Start a daemon in the background. Returns the Process; caller must
    /// terminate it (or kill-daemon) in cleanup.
    private static func startDaemon() async throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["serve", "--daemon"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Wait for the socket to appear (daemon is ready when it binds).
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: socketPath) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            FileManager.default.fileExists(atPath: socketPath),
            "daemon did not create socket within 5s"
        )
        // Small additional grace period for the listener to actually be accepting.
        try await Task.sleep(nanoseconds: 100_000_000)
        return proc
    }

    /// Run a CLI subcommand and return stdout + exit code.
    ///
    /// Drains stdout *before* waitUntilExit to avoid pipe-buffer deadlock if
    /// output exceeds ~64KB. These commands produce tiny output in practice,
    /// but the safe ordering is cheap.
    @discardableResult
    private static func runCLI(_ args: [String]) async throws -> (stdout: String, exit: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        return (stdout, proc.terminationStatus)
    }

    // MARK: - Tests

    @Test("status reports 'not running' when no daemon is active")
    func statusNoDaemon() async throws {
        try await Self.cleanSlate()
        let (out, exit) = try await Self.runCLI(["status"])
        #expect(out.contains("not running"))
        #expect(exit == 1, "status should exit non-zero when daemon is down")
    }

    @Test("daemon creates socket and pid file, status reports running")
    func daemonStartAndStatus() async throws {
        try await Self.cleanSlate()
        let proc = try await Self.startDaemon()
        defer { proc.terminate() }

        let (out, exit) = try await Self.runCLI(["status"])
        #expect(out.contains("daemon running"))
        #expect(out.contains(Self.socketPath))
        #expect(exit == 0)
    }

    @Test("MCP client can connect to daemon and list tools")
    func mcpClientListsTools() async throws {
        try await Self.cleanSlate()
        let proc = try await Self.startDaemon()
        defer { proc.terminate() }

        let connection = NWConnection(
            to: NWEndpoint.unix(path: Self.socketPath),
            using: .tcp
        )
        let transport = NetworkTransport(connection: connection)
        let client = Client(name: "daemon-lifecycle-test", version: "1.0")
        _ = try await client.connect(transport: transport)
        defer {
            Task { await client.disconnect() }
        }

        let response = try await client.listTools()
        #expect(!response.tools.isEmpty, "daemon should expose MCP tools")
        let names = Set(response.tools.map { $0.name })
        #expect(names.contains("preview_list"))
        #expect(names.contains("preview_snapshot"))
    }

    @Test("kill-daemon terminates the daemon and removes socket")
    func killDaemonCleansUp() async throws {
        try await Self.cleanSlate()
        let proc = try await Self.startDaemon()
        defer {
            // In case kill-daemon failed, force termination so the test doesn't leak.
            if proc.isRunning { proc.terminate() }
        }

        let (out, exit) = try await Self.runCLI(["kill-daemon", "--timeout", "5"])
        #expect(exit == 0, "kill-daemon should exit 0: \(out)")
        #expect(out.contains("stopped"))

        // Verify files were cleaned up.
        #expect(!FileManager.default.fileExists(atPath: Self.socketPath))

        // Verify status reports not running.
        let (statusOut, statusExit) = try await Self.runCLI(["status"])
        #expect(statusOut.contains("not running"))
        #expect(statusExit == 1)
    }

    @Test("starting a second daemon refuses and exits non-zero")
    func secondDaemonRefuses() async throws {
        try await Self.cleanSlate()
        let proc = try await Self.startDaemon()
        defer { proc.terminate() }

        let secondProc = Process()
        secondProc.executableURL = URL(fileURLWithPath: Self.binaryPath)
        secondProc.arguments = ["serve", "--daemon"]
        let errPipe = Pipe()
        secondProc.standardError = errPipe
        secondProc.standardOutput = FileHandle.nullDevice
        try secondProc.run()
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        secondProc.waitUntilExit()
        let stderr = String(data: errData, encoding: .utf8) ?? ""
        #expect(secondProc.terminationStatus != 0, "second daemon should fail")
        #expect(stderr.contains("already running"))
    }

    /// Catches a race: if the PID file is missing (daemon was started, PID
    /// write hadn't happened yet, or someone deleted it), a startup check
    /// based on PID alone lets a second daemon proceed. That second daemon
    /// would then unlink the still-live daemon's socket file, corrupting the
    /// running system.
    ///
    /// The correct check is a socket `connect()` probe: if anything is
    /// listening on the socket, refuse to start — regardless of PID file
    /// state.
    ///
    /// Without the fix this test would hang (second daemon rebinds and runs
    /// indefinitely), so we use a bounded wait and fail fast.
    @Test("second daemon refuses even when PID file is missing but socket is alive")
    func secondDaemonRefusesWithMissingPIDFile() async throws {
        try await Self.cleanSlate()
        let proc = try await Self.startDaemon()
        defer { proc.terminate() }

        // Simulate the race: PID file gone, but daemon still running.
        let pidPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp/serve.pid").path
        try? FileManager.default.removeItem(atPath: pidPath)

        let secondProc = Process()
        secondProc.executableURL = URL(fileURLWithPath: Self.binaryPath)
        secondProc.arguments = ["serve", "--daemon"]
        let errPipe = Pipe()
        secondProc.standardError = errPipe
        secondProc.standardOutput = FileHandle.nullDevice
        try secondProc.run()

        // Bounded wait: the second daemon should refuse and exit within ~2s.
        // If it doesn't, the race bug has corrupted state — fail the test
        // (rather than hanging) by terminating it.
        let deadline = Date().addingTimeInterval(2)
        while secondProc.isRunning && Date() < deadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let refusedInTime = !secondProc.isRunning
        if secondProc.isRunning {
            secondProc.terminate()
            secondProc.waitUntilExit()
        }
        let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
        let stderr = String(data: errData, encoding: .utf8) ?? ""

        #expect(refusedInTime, "second daemon should exit quickly, not keep running")
        #expect(secondProc.terminationStatus != 0, "second daemon should refuse")
        #expect(
            stderr.contains("already running"),
            "should detect live daemon via socket probe: \(stderr)"
        )

        // Daemon A must still be functional: its socket path must still exist
        // on disk and MCP clients must still be able to connect.
        #expect(
            FileManager.default.fileExists(atPath: Self.socketPath),
            "daemon A's socket file should not have been removed by failed daemon B"
        )

        let connection = NWConnection(
            to: NWEndpoint.unix(path: Self.socketPath),
            using: .tcp
        )
        let transport = NetworkTransport(connection: connection)
        let client = Client(name: "race-test", version: "1.0")
        _ = try await client.connect(transport: transport)
        await client.disconnect()
    }

    @Test("kill-daemon on stale PID file cleans up without error")
    func killDaemonStalePID() async throws {
        try await Self.cleanSlate()

        // Write a PID file pointing to a definitely-dead process.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        try "99999\n".write(
            to: home.appendingPathComponent("serve.pid"),
            atomically: true, encoding: .utf8
        )

        let (out, exit) = try await Self.runCLI(["kill-daemon"])
        #expect(exit == 0)
        #expect(out.contains("stale"))
    }
}

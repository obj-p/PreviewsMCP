import Foundation
import Testing

/// Integration tests for the `run` subcommand after its migration to
/// DaemonClient. Exercises the attached / detached flows end-to-end against
/// a real daemon and real preview compilation.
@Suite(.serialized)
struct RunCommandTests {

    // MARK: - Paths (reuse CLIRunner's)

    static var socketPath: String {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp/serve.sock").path
    }

    /// Kill any running daemon between tests so we start from a known state.
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
    }

    // MARK: - Tests

    /// `run --detach` should auto-start the daemon if needed, start a session,
    /// print the session UUID to stdout, and exit without blocking.
    @Test(
        "run --detach starts daemon, prints session UUID, exits",
        .timeLimit(.minutes(2))
    )
    func detachStartsSessionAndExits() async throws {
        try await Self.cleanSlate()
        defer { Task { try? await Self.cleanSlate() } }

        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
        let configPath = CLIRunner.repoRoot
            .appendingPathComponent("examples/.previewsmcp.json").path

        let result = try await CLIRunner.run(
            "run",
            arguments: [
                file, "--platform", "macos", "--config", configPath, "--detach",
            ]
        )
        #expect(result.exitCode == 0, "stderr: \(result.stderr)")

        // stdout should be a bare UUID (scriptable).
        let uuid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
        #expect(
            uuid.wholeMatch(of: uuidPattern) != nil,
            "stdout should be a bare UUID, got: '\(uuid)'"
        )

        // Daemon should still be running (detach does not tear it down).
        let status = try await CLIRunner.run("status")
        #expect(status.exitCode == 0, "daemon should be running after detach")
        #expect(status.stdout.contains("daemon running"))
    }

    /// `run` without --detach should block until signalled. Verified by
    /// spawning the process, waiting briefly for the session to come up,
    /// sending SIGINT, and checking the client exits within a reasonable
    /// bound. The daemon must survive; only the client exits.
    @Test(
        "run (attached) blocks until SIGINT, then exits cleanly",
        .timeLimit(.minutes(2))
    )
    func attachedBlocksUntilSignal() async throws {
        try await Self.cleanSlate()
        defer { Task { try? await Self.cleanSlate() } }

        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
        let configPath = CLIRunner.repoRoot
            .appendingPathComponent("examples/.previewsmcp.json").path

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
        proc.arguments = ["run", file, "--platform", "macos", "--config", configPath]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        // Wait for the daemon socket to appear and a session to be live.
        // The daemon is auto-started by the run client, so we check for the
        // socket file as the readiness signal.
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline,
            !FileManager.default.fileExists(atPath: Self.socketPath)
        {
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        #expect(
            FileManager.default.fileExists(atPath: Self.socketPath),
            "daemon socket should appear within 30s"
        )

        // The run client should still be blocking.
        #expect(proc.isRunning, "run should block until signal")

        // Send SIGINT; expect a clean exit within a couple of seconds.
        kill(proc.processIdentifier, SIGINT)
        let exitDeadline = Date().addingTimeInterval(10)
        while proc.isRunning && Date() < exitDeadline {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        if proc.isRunning { proc.terminate() }
        #expect(!proc.isRunning, "run should exit within 10s of SIGINT")

        // Daemon should still be running — it outlives the client.
        let status = try await CLIRunner.run("status")
        #expect(status.exitCode == 0, "daemon should stay alive after client exits")
    }

    /// When a daemon is already running, `run --detach` should connect to it
    /// (not spawn a second) and still create a session.
    @Test(
        "run --detach reuses an already-running daemon",
        .timeLimit(.minutes(2))
    )
    func detachReusesDaemon() async throws {
        try await Self.cleanSlate()
        defer { Task { try? await Self.cleanSlate() } }

        // Pre-start the daemon manually.
        let daemonStarter = Process()
        daemonStarter.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
        daemonStarter.arguments = ["serve", "--daemon"]
        daemonStarter.standardOutput = FileHandle.nullDevice
        daemonStarter.standardError = FileHandle.nullDevice
        try daemonStarter.run()
        defer { if daemonStarter.isRunning { daemonStarter.terminate() } }

        // Wait for socket to be ready.
        let readyDeadline = Date().addingTimeInterval(5)
        while Date() < readyDeadline,
            !FileManager.default.fileExists(atPath: Self.socketPath)
        {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try await Task.sleep(nanoseconds: 100_000_000)

        // Record daemon PID.
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        let pidBefore =
            (try? String(contentsOf: home.appendingPathComponent("serve.pid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        // Detach should reuse the existing daemon.
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
        let configPath = CLIRunner.repoRoot
            .appendingPathComponent("examples/.previewsmcp.json").path
        let result = try await CLIRunner.run(
            "run",
            arguments: [
                file, "--platform", "macos", "--config", configPath, "--detach",
            ]
        )
        #expect(result.exitCode == 0, "stderr: \(result.stderr)")

        // Daemon PID must be unchanged.
        let pidAfter =
            (try? String(contentsOf: home.appendingPathComponent("serve.pid"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(
            pidAfter == pidBefore,
            "daemon should not have been restarted (before=\(pidBefore ?? "nil"), after=\(pidAfter ?? "nil"))"
        )
    }
}

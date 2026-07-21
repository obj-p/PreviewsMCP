import Foundation
import Testing

/// Integration tests for the `run` subcommand after its migration to
/// DaemonClient. Exercises the attached / detached flows end-to-end against
/// a real daemon and real preview compilation.
///
/// These tests share global daemon state with DaemonLifecycleTests in
/// another test target. Swift Testing may run different suites in parallel
/// even when each is .serialized, which causes one suite's cleanup to stomp
/// on the other's daemon. Guard with a filesystem lock (DaemonTestLock) so
/// only one daemon-owning test runs at a time.
@Suite(.serialized)
struct RunCommandTests {
    static var daemonDir: URL {
        URL(fileURLWithPath: DaemonTestLock.effectiveSocketDir, isDirectory: true)
    }

    static var socketPath: String {
        daemonDir.appendingPathComponent("serve.sock").path
    }

    /// Environment for a directly-spawned CLI/daemon: the current env with
    /// `PREVIEWSMCP_SOCKET_DIR` forced to this run's per-run socket dir (#283)
    /// so it resolves the same socket as CLIRunner-spawned probes.
    static func childEnv() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PREVIEWSMCP_SOCKET_DIR"] = DaemonTestLock.effectiveSocketDir
        return env
    }

    /// Kill any running daemon between tests so we start from a known state.
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    // MARK: - Tests

    @Test(
        "run --detach starts daemon, prints session UUID, exits",
        .timeLimit(.minutes(10))
    )
    func detachStartsSessionAndExits() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

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

            let uuid = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let uuidPattern = /^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$/
            #expect(
                uuid.wholeMatch(of: uuidPattern) != nil,
                "stdout should be a bare UUID, got: '\(uuid)'"
            )

            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should be running after detach")
            #expect(status.stdout.contains("daemon running"))
        }
    }

    /// `run` without --detach should:
    ///   1. auto-start the daemon,
    ///   2. create a live session (verified via a "Session ID:" line from
    ///      the daemon's log relay in the client's stderr),
    ///   3. block until signalled,
    ///   4. exit cleanly on SIGINT while the daemon keeps running.
    ///
    /// Reading stderr for "Session ID:" is deliberate — the socket file
    /// appears before preview_start completes, so waiting on the socket
    /// alone doesn't prove a session was actually rendered. A faulty run
    /// that never called preview_start would pass that weaker check.
    @Test(
        "run (attached) creates a live session then exits on SIGINT",
        .timeLimit(.minutes(10))
    )
    func attachedBlocksUntilSignal() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
            proc.arguments = ["run", file, "--platform", "macos", "--config", configPath]
            proc.environment = Self.childEnv()
            proc.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            try proc.run()

            let sessionIDPattern = /Session ID: [0-9a-fA-F-]{36}/
            let sawSession = try await Self.waitForStderrMatch(
                pipe: stderrPipe,
                pattern: sessionIDPattern,
                timeout: 60
            )
            #expect(sawSession, "daemon should report Session ID within 60s")
            #expect(proc.isRunning, "run should block after session is established")

            kill(proc.processIdentifier, SIGINT)
            let clock = SuspendingClock()
            let exitDeadline = clock.now.advanced(by: .seconds(10))
            while proc.isRunning, clock.now < exitDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
            #expect(!proc.isRunning, "run should exit within 10s of SIGINT")

            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should stay alive after client exits")
        }
    }

    /// Guards the setsid detachment. Without `setsid()` running before the
    /// socket listener starts, SIGHUP to the `run` client cascades to the
    /// daemon (shared process group) and kills it. With the fix, the daemon
    /// is in its own session and survives.
    ///
    /// `run` doesn't handle SIGHUP itself — the default action terminates
    /// the client. That's expected; the *daemon* surviving is what we test.
    @Test(
        "daemon survives SIGHUP to the run client",
        .timeLimit(.minutes(10))
    )
    func daemonSurvivesClientSIGHUP() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
            proc.arguments = ["run", file, "--platform", "macos", "--config", configPath]
            proc.environment = Self.childEnv()
            proc.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            try proc.run()

            // Wait for the session to be live (same signal as the SIGINT test).
            let sessionIDPattern = /Session ID: [0-9a-fA-F-]{36}/
            let sawSession = try await Self.waitForStderrMatch(
                pipe: stderrPipe,
                pattern: sessionIDPattern,
                timeout: 60
            )
            #expect(sawSession, "daemon should report Session ID within 60s")
            #expect(proc.isRunning)

            kill(proc.processIdentifier, SIGHUP)
            let clock = SuspendingClock()
            let exitDeadline = clock.now.advanced(by: .seconds(10))
            while proc.isRunning, clock.now < exitDeadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
            #expect(!proc.isRunning, "run should exit after SIGHUP")

            // Daemon must still be alive — setsid was supposed to detach it
            // from the client's process group.
            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should survive SIGHUP to client")
            #expect(status.stdout.contains("daemon running"))
        }
    }

    @Test(
        "run --detach reuses an already-running daemon",
        .timeLimit(.minutes(10))
    )
    func detachReusesDaemon() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let daemonStarter = Process()
            daemonStarter.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
            daemonStarter.arguments = ["serve", "--daemon"]
            daemonStarter.environment = Self.childEnv()
            daemonStarter.standardOutput = FileHandle.nullDevice
            daemonStarter.standardError = FileHandle.nullDevice
            try daemonStarter.run()
            defer { if daemonStarter.isRunning { daemonStarter.terminate() } }

            let clock = SuspendingClock()
            let readyDeadline = clock.now.advanced(by: .seconds(5))
            while clock.now < readyDeadline,
                  !FileManager.default.fileExists(atPath: Self.socketPath)
            {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)

            let pidBefore =
                (try? String(
                    contentsOf: Self.daemonDir.appendingPathComponent("serve.pid"),
                    encoding: .utf8
                ))?
                .trimmingCharacters(in: .whitespacesAndNewlines)

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

            let pidAfter =
                (try? String(
                    contentsOf: Self.daemonDir.appendingPathComponent("serve.pid"),
                    encoding: .utf8
                ))?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(
                pidAfter == pidBefore,
                "daemon should not have been restarted (before=\(pidBefore ?? "nil"), after=\(pidAfter ?? "nil"))"
            )
        }
    }

    // MARK: - Helpers

    private static func waitForStderrMatch(
        pipe: Pipe,
        pattern: Regex<some Any>,
        timeout: TimeInterval
    ) async throws -> Bool {
        let buffer = PipeBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                buffer.append(text)
            }
        }
        defer { handle.readabilityHandler = nil }

        let clock = SuspendingClock()
        let deadline = clock.now.advanced(by: .seconds(timeout))
        while clock.now < deadline {
            if buffer.contents().contains(pattern) { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

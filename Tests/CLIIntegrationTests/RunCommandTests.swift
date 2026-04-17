import Foundation
import Testing

/// Thread-safe accumulator for a pipe's stderr output. The readabilityHandler
/// closure runs on a background queue; this class synchronizes writes so the
/// poll loop can safely read contents().
private final class StderrBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ s: String) {
        lock.lock(); defer { lock.unlock() }
        text.append(s)
    }

    func contents() -> String {
        lock.lock(); defer { lock.unlock() }
        return text
    }
}

/// Integration tests for the `run` subcommand after its migration to
/// DaemonClient. Exercises the attached / detached flows end-to-end against
/// a real daemon and real preview compilation.
///
/// These tests share global daemon state (~/.previewsmcp/serve.sock) with
/// DaemonLifecycleTests in another test target. Swift Testing may run
/// different suites in parallel even when each is .serialized, which causes
/// one suite's cleanup to stomp on the other's daemon. Guard with a
/// filesystem lock (DaemonTestLock) so only one daemon-owning test runs at
/// a time.
@Suite(.serialized)
struct RunCommandTests {

    static var socketPath: String {
        if let dir = CLIRunner.socketDir {
            return (dir as NSString).appendingPathComponent("serve.sock")
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp/serve.sock").path
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
            proc.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            CLIRunner.applySocketDir(to: proc)
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
            let exitDeadline = Date().addingTimeInterval(10)
            while proc.isRunning && Date() < exitDeadline {
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
            proc.standardOutput = FileHandle.nullDevice
            let stderrPipe = Pipe()
            proc.standardError = stderrPipe
            CLIRunner.applySocketDir(to: proc)
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
            let exitDeadline = Date().addingTimeInterval(10)
            while proc.isRunning && Date() < exitDeadline {
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
            daemonStarter.standardOutput = FileHandle.nullDevice
            daemonStarter.standardError = FileHandle.nullDevice
            CLIRunner.applySocketDir(to: daemonStarter)
            try daemonStarter.run()
            defer { if daemonStarter.isRunning { daemonStarter.terminate() } }

            let readyDeadline = Date().addingTimeInterval(5)
            while Date() < readyDeadline,
                !FileManager.default.fileExists(atPath: Self.socketPath)
            {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            try await Task.sleep(nanoseconds: 100_000_000)

            let pidDir = URL(fileURLWithPath: Self.socketPath)
                .deletingLastPathComponent()
            let pidBefore =
                (try? String(
                    contentsOf: pidDir.appendingPathComponent("serve.pid"),
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
                    contentsOf: pidDir.appendingPathComponent("serve.pid"),
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

    private static func waitForStderrMatch<Output>(
        pipe: Pipe,
        pattern: Regex<Output>,
        timeout: TimeInterval
    ) async throws -> Bool {
        let buffer = StderrBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fileHandle in
            let data = fileHandle.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                buffer.append(text)
            }
        }
        defer { handle.readabilityHandler = nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.contents().contains(pattern) { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }
}

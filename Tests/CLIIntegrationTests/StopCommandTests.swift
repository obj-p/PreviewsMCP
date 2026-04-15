import Foundation
import Testing

/// Integration tests for the `stop` subcommand. Covers session
/// resolution, explicit `--session`, `--all`, and error paths.
@Suite(.serialized)
struct StopCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
    }

    // MARK: - Local validation

    @Test("stop rejects --all combined with --session")
    func stopRejectsAllWithSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "stop", arguments: ["--all", "--session", "deadbeef"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("--all cannot be combined"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("stop rejects --all combined with --file")
    func stopRejectsAllWithFile() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "stop", arguments: ["--all", "--file", "/tmp/ignored.swift"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("--all cannot be combined"),
                "stderr: \(result.stderr)"
            )
        }
    }

    // MARK: - No-session paths

    @Test("stop errors when no session is running")
    func stopNoSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run("stop")
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("No session found to stop"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("stop --all on an empty daemon is a no-op success")
    func stopAllWithNoSessions() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run("stop", arguments: ["--all"])
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("No active sessions to stop"),
                "stderr: \(result.stderr)"
            )
        }
    }

    // MARK: - Happy paths

    /// Start a macOS session, stop it by default resolution, confirm the
    /// daemon reports it closed and that no sessions remain.
    @Test(
        "stop closes the sole running session",
        .timeLimit(.minutes(2))
    )
    func stopSoleSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")
            let sessionID = runResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let stopResult = try await CLIRunner.run("stop")
            #expect(stopResult.exitCode == 0, "stderr: \(stopResult.stderr)")
            #expect(
                stopResult.stderr.contains("closed"),
                "daemon should echo a close confirmation: \(stopResult.stderr)"
            )
            #expect(
                stopResult.stderr.contains(sessionID),
                "close confirmation should name the session: \(stopResult.stderr)"
            )

            // A follow-up stop should now fail — no session is running.
            let second = try await CLIRunner.run("stop")
            #expect(second.exitCode != 0)
            #expect(
                second.stderr.contains("No session found"),
                "stderr: \(second.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Verifies that `--all` closes every session in a single invocation
    /// by starting two sessions against different preview files and
    /// confirming a subsequent `stop` sees nothing left.
    @Test(
        "stop --all closes every active session",
        .timeLimit(.minutes(3))
    )
    func stopAllClosesEverything() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let fileA = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let fileB = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoProviderPreview.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let runA = try await CLIRunner.run(
                "run",
                arguments: [
                    fileA, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runA.exitCode == 0, "detach A stderr: \(runA.stderr)")

            let runB = try await CLIRunner.run(
                "run",
                arguments: [
                    fileB, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runB.exitCode == 0, "detach B stderr: \(runB.stderr)")

            let stopAll = try await CLIRunner.run("stop", arguments: ["--all"])
            #expect(stopAll.exitCode == 0, "stderr: \(stopAll.stderr)")

            // A follow-up --all run should report nothing left.
            let second = try await CLIRunner.run("stop", arguments: ["--all"])
            #expect(second.exitCode == 0, "stderr: \(second.stderr)")
            #expect(
                second.stderr.contains("No active sessions to stop"),
                "stderr: \(second.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Explicit --session bypasses the session-list lookup. Verifies the
    /// daemon accepts the UUID and references it in its response.
    @Test(
        "stop --session targets a specific session by UUID",
        .timeLimit(.minutes(2))
    )
    func stopExplicitSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0)
            let sessionID = runResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let result = try await CLIRunner.run(
                "stop", arguments: ["--session", sessionID]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains(sessionID),
                "close confirmation should name the session: \(result.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

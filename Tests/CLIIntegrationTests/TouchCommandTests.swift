import Foundation
import Testing

/// Integration tests for the `touch` subcommand. Covers local validation,
/// error paths, and — gated on simulator availability — a happy-path tap
/// + swipe round trip against an iOS session.
@Suite(.serialized)
struct TouchCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    // MARK: - Local validation (no daemon required)

    @Test("touch rejects partial swipe endpoints")
    func touchRejectsPartialSwipe() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "touch", arguments: ["100", "200", "--to-x", "300"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("must be provided together"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("touch rejects non-positive --duration")
    func touchRejectsNonPositiveDuration() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "touch",
                arguments: [
                    "100", "200", "--to-x", "300", "--to-y", "400", "--duration", "0",
                ]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("--duration must be positive"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("touch rejects --duration without swipe endpoints")
    func touchRejectsDurationWithoutSwipe() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "touch", arguments: ["100", "200", "--duration", "0.5"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("--duration only applies to swipes"),
                "stderr: \(result.stderr)"
            )
        }
    }

    // MARK: - No-session error path

    @Test("touch errors when no session is running")
    func touchNoSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "touch", arguments: ["100", "200"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("No session found"),
                "stderr: \(result.stderr)"
            )
        }
    }

    /// The daemon's `preview_touch` tool is iOS-only. Against a running
    /// macOS session it should surface the iOS-only error.
    @Test(
        "touch against a macOS session surfaces an iOS-only error",
        .timeLimit(.minutes(20))
    )
    func touchRejectsMacOSSession() async throws {
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

            let result = try await CLIRunner.run(
                "touch", arguments: ["100", "200"]
            )
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("only supported for iOS simulator previews"),
                "macOS session should surface the daemon's iOS-only error: \(result.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    // iOS happy path is tested in IOSCLIWorkflowTests.iosCLIWorkflow
    // to avoid redundant daemon + simulator setup.
}

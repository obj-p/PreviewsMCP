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

    // Local (pre-daemon) argument validation — partial swipe endpoints,
    // non-positive --duration, --duration without swipe — moved to
    // PreviewsCLITests/CLIValidationTests.swift, which invokes TouchCommand
    // in-process instead of spawning a subprocess + daemon.

    // "touch errors when no session is running" moved to
    // PreviewsCLITests/TouchCommandLogicTests.swift, which invokes
    // TouchCommand.execute(on:) against a FakeDaemonClient instead of
    // spawning a subprocess + daemon.

    /// The daemon's `preview_touch` tool is iOS-only. Against a running
    /// macOS session it should surface the iOS-only error.
    @Test(
        "touch against a macOS session surfaces an iOS-only error",
        .timeLimit(.minutes(5))
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

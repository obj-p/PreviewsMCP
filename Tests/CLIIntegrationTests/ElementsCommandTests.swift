import Foundation
import Testing

/// Integration tests for the `elements` subcommand. Covers local
/// validation, error paths, and (if a simulator is available) a happy-path
/// iOS round trip that confirms the daemon returns a JSON accessibility
/// tree.
@Suite(.serialized)
struct ElementsCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    @Test("elements errors when no session is running")
    func elementsNoSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run("elements")
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("No session found"),
                "stderr: \(result.stderr)"
            )
        }
    }

    /// The daemon's `preview_elements` tool is iOS-only. Exercising it
    /// against a running macOS session should surface the daemon's error
    /// cleanly.
    @Test(
        "elements against a macOS session surfaces an iOS-only error",
        .timeLimit(.minutes(10))
    )
    func elementsRejectsMacOSSession() async throws {
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

            let result = try await CLIRunner.run("elements")
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("only available for iOS simulator previews"),
                "macOS session should surface the daemon's iOS-only error: \(result.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    // iOS happy path is tested in IOSCLIWorkflowTests.iosCLIWorkflow
    // to avoid redundant daemon + simulator setup.
}

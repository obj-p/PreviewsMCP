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

    /// Happy path: start an iOS session, dump the accessibility tree,
    /// confirm stdout is well-formed JSON with the expected shape. Gated
    /// on a simulator being available so local developer machines without
    /// simulators don't fail.
    @Test(
        "elements returns a JSON accessibility tree for an iOS session",
        .timeLimit(.minutes(20))
    )
    func elementsReturnsJSONTree() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping elements iOS test")
                return
            }

            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "ios", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            let result = try await CLIRunner.run("elements")
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            guard let data = result.stdout.data(using: .utf8) else {
                Issue.record("stdout was not UTF-8: \(result.stdout)")
                return
            }
            let parsed = try JSONSerialization.jsonObject(with: data)
            #expect(
                parsed is [String: Any] || parsed is [Any],
                "elements stdout should be a JSON object or array: \(result.stdout.prefix(200))"
            )

            // Filter mode should still produce valid JSON.
            let filterResult = try await CLIRunner.run(
                "elements", arguments: ["--filter", "interactable"]
            )
            #expect(filterResult.exitCode == 0, "filter stderr: \(filterResult.stderr)")
            if let filterData = filterResult.stdout.data(using: .utf8) {
                _ = try JSONSerialization.jsonObject(with: filterData)
            }

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

import Foundation
import Testing

/// Integration tests for the `switch` subcommand.
@Suite(.serialized)
struct SwitchCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    @Test("switch with negative index fails locally")
    func switchRejectsNegativeIndex() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let result = try await CLIRunner.run("switch", arguments: ["--", "-1"])
            #expect(result.exitCode != 0)
            #expect(result.stderr.contains("non-negative"))
        }
    }

    @Test("switch errors when no session is running")
    func switchNoSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let result = try await CLIRunner.run("switch", arguments: ["0"])
            #expect(result.exitCode != 0)
            #expect(result.stderr.contains("No session found to switch"))
        }
    }

    /// Full round-trip: start a session showing preview 0, switch to preview
    /// 1, snapshot both, and confirm the rendered output differs. Preview 0
    /// in the SPM example renders a populated ToDo list; preview 1 renders
    /// the empty state.
    @Test(
        "switch changes the active preview in a live session",
        .timeLimit(.minutes(10))
    )
    func switchChangesActivePreview() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path
            let before = tempDir.appendingPathComponent("preview0.png").path
            let after = tempDir.appendingPathComponent("preview1.png").path

            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            // Snapshot the default (preview 0).
            let beforeResult = try await CLIRunner.run(
                "snapshot",
                arguments: [file, "-o", before, "--platform", "macos"]
            )
            #expect(beforeResult.exitCode == 0)

            // Switch to preview 1.
            let switchResult = try await CLIRunner.run(
                "switch", arguments: ["1"]
            )
            #expect(switchResult.exitCode == 0, "stderr: \(switchResult.stderr)")
            // Daemon response lists the new active preview.
            #expect(
                switchResult.stderr.contains("<- active"),
                "daemon summary should mark the newly active preview: \(switchResult.stderr)"
            )

            // Snapshot preview 1.
            let afterResult = try await CLIRunner.run(
                "snapshot",
                arguments: [file, "-o", after, "--platform", "macos"]
            )
            #expect(afterResult.exitCode == 0)

            let beforeData = try Data(contentsOf: URL(fileURLWithPath: before))
            let afterData = try Data(contentsOf: URL(fileURLWithPath: after))
            #expect(
                beforeData != afterData,
                "preview 0 and preview 1 should produce different snapshots"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// `switch` with an out-of-range preview index should surface the daemon's
    /// error message cleanly.
    @Test(
        "switch with out-of-range index reports an error",
        .timeLimit(.minutes(10))
    )
    func switchOutOfRange() async throws {
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

            // ToDoView only has 2 previews (indices 0 and 1).
            let result = try await CLIRunner.run("switch", arguments: ["99"])
            #expect(result.exitCode != 0)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

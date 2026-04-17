import Foundation
import Testing

/// Integration tests for the `configure` subcommand. Covers session
/// resolution, trait application (verified via snapshot diff), and error
/// paths. Uses DaemonTestLock so we don't race with other daemon-touching
/// suites across test targets.
@Suite(.serialized)
struct ConfigureCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    // MARK: - Validation (no daemon required)

    @Test("configure without any trait flag fails with a useful message")
    func configureRequiresAtLeastOneTrait() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run("configure")
            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("No traits specified"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("configure with invalid color scheme fails locally")
    func configureRejectsInvalidTrait() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "configure",
                arguments: ["--color-scheme", "plaid"]
            )
            #expect(result.exitCode != 0)
            #expect(result.stderr.lowercased().contains("color scheme"))
        }
    }

    // MARK: - No-session error path

    @Test("configure errors when no session is running")
    func configureNoSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "configure",
                arguments: ["--color-scheme", "dark"]
            )
            #expect(result.exitCode != 0)
            #expect(result.stderr.contains("No session found to configure"))
        }
    }

    // MARK: - Happy path

    /// Full round trip: start a session, configure it to dark mode,
    /// verify the session is actually reconfigured by snapshotting
    /// before and after and asserting the PNG output differs.
    @Test(
        "configure dark mode changes the rendered snapshot",
        .timeLimit(.minutes(10))
    )
    func configureChangesRenderedOutput() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path
            let beforePath = tempDir.appendingPathComponent("before.png").path
            let afterPath = tempDir.appendingPathComponent("after.png").path

            // Start a live session via run --detach.
            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            // Snapshot before config change — uses session's current (light) traits.
            let beforeResult = try await CLIRunner.run(
                "snapshot",
                arguments: [file, "-o", beforePath, "--platform", "macos"]
            )
            #expect(beforeResult.exitCode == 0, "before stderr: \(beforeResult.stderr)")

            // Configure to dark.
            let configResult = try await CLIRunner.run(
                "configure",
                arguments: ["--color-scheme", "dark"]
            )
            #expect(configResult.exitCode == 0, "configure stderr: \(configResult.stderr)")
            #expect(
                configResult.stderr.contains("Configured session"),
                "configure should report what changed: \(configResult.stderr)"
            )

            // Snapshot after config change — should differ from before.
            let afterResult = try await CLIRunner.run(
                "snapshot",
                arguments: [file, "-o", afterPath, "--platform", "macos"]
            )
            #expect(afterResult.exitCode == 0, "after stderr: \(afterResult.stderr)")

            let beforeData = try Data(contentsOf: URL(fileURLWithPath: beforePath))
            let afterData = try Data(contentsOf: URL(fileURLWithPath: afterPath))
            let diffMessage =
                "dark-mode snapshot (\(afterData.count) bytes) should differ from "
                + "light-mode snapshot (\(beforeData.count) bytes)"
            #expect(beforeData != afterData, Comment(rawValue: diffMessage))

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// `--color-scheme ""` is the documented signal to clear a trait. The
    /// daemon's response summary lists the session's *active* traits after
    /// the change, so an empty summary proves the trait actually went from
    /// set to unset (rather than the old no-op "empty is ignored" bug).
    @Test(
        "configure --color-scheme empty-string clears the trait",
        .timeLimit(.minutes(10))
    )
    func configureClearsTrait() async throws {
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

            // Set the trait so there's something non-default to clear.
            let setResult = try await CLIRunner.run(
                "configure",
                arguments: ["--color-scheme", "dark"]
            )
            #expect(setResult.exitCode == 0)
            #expect(
                setResult.stderr.contains("colorScheme=dark"),
                "daemon summary should show the set value: \(setResult.stderr)"
            )

            // Clear it. After, the daemon summary for the session's active
            // traits should no longer mention colorScheme.
            let clearResult = try await CLIRunner.run(
                "configure",
                arguments: ["--color-scheme", ""]
            )
            #expect(clearResult.exitCode == 0, "stderr: \(clearResult.stderr)")
            #expect(
                !clearResult.stderr.contains("colorScheme="),
                "daemon summary should not mention colorScheme after clear: \(clearResult.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Verifies --session <uuid> takes priority over any file-based lookup
    /// and that the daemon identifies the session in its response.
    @Test(
        "configure --session targets a specific session by UUID",
        .timeLimit(.minutes(10))
    )
    func configureExplicitSession() async throws {
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
                "configure",
                arguments: ["--session", sessionID, "--color-scheme", "dark"]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains(sessionID),
                "daemon response should reference the explicit session UUID"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

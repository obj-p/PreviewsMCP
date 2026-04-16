import Foundation
import Testing

/// Integration tests for the `touch` subcommand. Covers local validation,
/// error paths, and — gated on simulator availability — a happy-path tap
/// + swipe round trip against an iOS session.
@Suite(.serialized)
struct TouchCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
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
        .timeLimit(.minutes(10))
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

    /// Happy path: start an iOS session, send a tap and a swipe, assert
    /// the daemon reports both as successful.
    @Test(
        "touch sends tap and swipe to an iOS session",
        .timeLimit(.minutes(10))
    )
    func touchIOSHappyPath() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping touch iOS test")
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

            // Tap. Pin the assertion to the full coordinate string so
            // that a regression mis-wiring x/y still fails.
            let tapResult = try await CLIRunner.run(
                "touch", arguments: ["120", "200"]
            )
            #expect(tapResult.exitCode == 0, "tap stderr: \(tapResult.stderr)")
            #expect(
                tapResult.stderr.contains("Tap sent at (120, 200)"),
                "daemon should echo the tap coordinates: \(tapResult.stderr)"
            )

            // Swipe. Same: require the endpoints so a lost toX/toY wiring
            // can't slip through.
            let swipeResult = try await CLIRunner.run(
                "touch",
                arguments: [
                    "40", "300", "--to-x", "300", "--to-y", "300", "--duration", "0.4",
                ]
            )
            #expect(swipeResult.exitCode == 0, "swipe stderr: \(swipeResult.stderr)")
            #expect(
                swipeResult.stderr.contains("Swipe from (40,300) to (300,300)"),
                "daemon should echo the full swipe endpoints: \(swipeResult.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

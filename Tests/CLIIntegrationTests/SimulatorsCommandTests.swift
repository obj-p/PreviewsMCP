import Foundation
import Testing

/// Integration tests for the `simulators` subcommand. Verifies that the
/// CLI auto-starts the daemon and surfaces the `simulator_list` tool's
/// human-readable output on stdout.
@Suite(.serialized)
struct SimulatorsCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
    }

    /// Happy path: run against the real `simctl`. Gated on a simulator
    /// actually being available so machines without Xcode simulators
    /// (e.g. stripped CI runners) don't fail — the daemon would still
    /// print "No available simulator devices found." in that case.
    @Test(
        "simulators prints one line per available device on stdout",
        .timeLimit(.minutes(2))
    )
    func simulatorsPrintsAvailableDevices() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping simulators test")
                return
            }

            try await Self.cleanSlate()

            let result = try await CLIRunner.run("simulators")
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let lines = result.stdout
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
            #expect(!lines.isEmpty, "should list at least one device: \(result.stdout)")

            // Daemon formats each line as "<name> — <udid> [BOOTED]? (<runtime>)".
            // The em-dash plus parentheses are the structural markers; require
            // them so a regression that dropped fields would be caught.
            for line in lines {
                #expect(
                    line.contains(" — ") && line.contains("(") && line.contains(")"),
                    "line should contain name, em-dash, udid and runtime: \(line)"
                )
            }

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

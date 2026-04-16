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

    /// Runs on every machine: whether or not any simulators exist, the
    /// command must succeed with a non-empty payload on stdout. When a
    /// simulator is available we tighten the assertion to the per-line
    /// structural format; otherwise we check the daemon's "no devices"
    /// sentinel. This also implicitly verifies daemon auto-start.
    @Test(
        "simulators succeeds with either device lines or the no-devices sentinel",
        .timeLimit(.minutes(2))
    )
    func simulatorsAlwaysProducesOutput() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run("simulators")
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            #expect(!stdout.isEmpty, "simulators must emit something on stdout: \(result.stdout)")

            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            let hasSimulator = simResult.exitCode == 0 && simResult.stdout.contains("iPhone")

            if hasSimulator {
                let lines =
                    stdout
                    .split(separator: "\n", omittingEmptySubsequences: true)
                    .map(String.init)
                #expect(!lines.isEmpty, "should list at least one device: \(stdout)")

                // Daemon formats each line as "<name> — <udid> [BOOTED]? (<runtime>)".
                // The em-dash plus parentheses are the structural markers; require
                // them so a regression that dropped fields would be caught.
                for line in lines {
                    #expect(
                        line.contains(" — ") && line.contains("(") && line.contains(")"),
                        "line should contain name, em-dash, udid and runtime: \(line)"
                    )
                }
            } else {
                #expect(
                    stdout.contains("No available simulator devices found"),
                    "should surface the no-devices sentinel verbatim: \(stdout)"
                )
            }

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    @Test(
        "simulators --json emits valid JSON with expected fields",
        .timeLimit(.minutes(2))
    )
    func simulatorsJSON() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            let result = try await CLIRunner.run(
                "simulators", arguments: ["--json"]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let data = stdout.data(using: .utf8) else {
                Issue.record("stdout was not UTF-8")
                return
            }
            let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            #expect(parsed != nil, "stdout should be a JSON object")
            #expect(
                parsed?["simulators"] is [Any],
                "should contain a 'simulators' array: \(stdout.prefix(200))"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

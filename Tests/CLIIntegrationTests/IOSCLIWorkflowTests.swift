import Foundation
import Testing

/// Combined iOS CLI workflow test. Boots one iOS session and exercises
/// touch, elements, variants, and stop in sequence — paying the
/// expensive daemon + compile + simulator setup cost once instead of
/// four times.
///
/// Individual command suites still test macOS paths, error paths, and
/// local validation independently. This test covers the iOS-specific
/// daemon code paths end-to-end.
@Suite(.serialized)
struct IOSCLIWorkflowTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    @Test(
        "iOS CLI workflow: touch, elements, variants, stop",
        .timeLimit(.minutes(20))
    )
    func iosCLIWorkflow() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping iOS CLI workflow")
                return
            }

            try await Self.cleanSlate()

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            // Start a single iOS session for the entire workflow.
            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "ios", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            // -- touch: tap --
            let tapResult = try await CLIRunner.run(
                "touch", arguments: ["120", "200"]
            )
            #expect(tapResult.exitCode == 0, "tap stderr: \(tapResult.stderr)")
            #expect(
                tapResult.stderr.contains("Tap sent at (120, 200)"),
                "daemon should echo the tap coordinates: \(tapResult.stderr)"
            )

            // -- touch: swipe --
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

            // -- elements --
            let elemResult = try await CLIRunner.run("elements")
            #expect(elemResult.exitCode == 0, "elements stderr: \(elemResult.stderr)")

            guard let data = elemResult.stdout.data(using: .utf8) else {
                Issue.record("elements stdout was not UTF-8: \(elemResult.stdout)")
                return
            }
            let parsed = try JSONSerialization.jsonObject(with: data)
            #expect(
                parsed is [String: Any] || parsed is [Any],
                "elements stdout should be a JSON object or array: \(elemResult.stdout.prefix(200))"
            )

            let filterResult = try await CLIRunner.run(
                "elements", arguments: ["--filter", "interactable"]
            )
            #expect(filterResult.exitCode == 0, "filter stderr: \(filterResult.stderr)")
            if let filterData = filterResult.stdout.data(using: .utf8) {
                _ = try JSONSerialization.jsonObject(with: filterData)
            }

            // -- variants (needs its own session via file arg) --
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let varResult = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", "light",
                    "--variant", "dark",
                    "-o", tempDir.path,
                    "--platform", "ios",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ])
            #expect(varResult.exitCode == 0, "variants stderr: \(varResult.stderr)")
            #expect(
                varResult.stderr.contains("Captured 2/2 variants"),
                "variants stderr: \(varResult.stderr)"
            )
            try CLIRunner.assertValidJPEG(
                at: tempDir.appendingPathComponent("light.jpg").path)
            try CLIRunner.assertValidJPEG(
                at: tempDir.appendingPathComponent("dark.jpg").path)

            // -- stop (last — tears down the session) --
            let stopResult = try await CLIRunner.run("stop")
            #expect(stopResult.exitCode == 0, "stop stderr: \(stopResult.stderr)")
            #expect(
                stopResult.stderr.contains("iOS preview session"),
                "daemon should route through the iOS stop path: \(stopResult.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

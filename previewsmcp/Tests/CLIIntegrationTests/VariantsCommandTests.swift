import Foundation
import Testing

@Suite("CLI variants command", .serialized)
struct VariantsCommandTests {
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    // MARK: - Happy paths

    @Test("Captures multiple presets to distinct files", .timeLimit(.minutes(5)))
    func capturesMultiplePresets() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", "light",
                    "--variant", "dark",
                    "-o", tempDir.path,
                    "--platform", "macos",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ]
            )

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("Captured 2/2 variants"),
                "Expected success summary in stderr: \(result.stderr)"
            )

            let lightPath = tempDir.appendingPathComponent("light.jpg").path
            let darkPath = tempDir.appendingPathComponent("dark.jpg").path
            try CLIRunner.assertValidJPEG(at: lightPath)
            try CLIRunner.assertValidJPEG(at: darkPath)

            // light and dark should produce visually different images
            let lightData = try Data(contentsOf: URL(fileURLWithPath: lightPath))
            let darkData = try Data(contentsOf: URL(fileURLWithPath: darkPath))
            #expect(lightData != darkData, "light and dark variants should differ")

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    @Test("JSON variant uses custom label as filename", .timeLimit(.minutes(5)))
    func jsonVariantUsesCustomLabel() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant",
                    #"{"colorScheme":"dark","dynamicTypeSize":"large","label":"my-custom-label"}"#,
                    "-o", tempDir.path,
                    "--platform", "macos",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ]
            )

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            let outPath = tempDir.appendingPathComponent("my-custom-label.jpg").path
            try CLIRunner.assertValidJPEG(at: outPath)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    @Test("PNG format produces valid PNG files", .timeLimit(.minutes(5)))
    func pngFormat() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", "light",
                    "--format", "png",
                    "-o", tempDir.path,
                    "--platform", "macos",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ]
            )

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: tempDir.appendingPathComponent("light.png").path)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    // iOS variants path is tested in IOSCLIWorkflowTests.iosCLIWorkflow
    // to avoid redundant daemon + simulator setup.

    /// When a session is already running for the target file, `variants`
    /// should reuse it rather than spinning up an ephemeral one. Observable
    /// proof: after the variants run, the session is still alive (stop
    /// --all reports it).
    @Test(
        "variants reuses an already-running session",
        .timeLimit(.minutes(5))
    )
    func variantsReusesLiveSession() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

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
                "variants",
                arguments: [
                    file,
                    "--variant", "light",
                    "--variant", "dark",
                    "-o", tempDir.path,
                    "--platform", "macos",
                    "--config", configPath,
                ]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            // The session should still exist after variants finishes.
            let stopResult = try await CLIRunner.run(
                "stop", arguments: ["--all"]
            )
            #expect(stopResult.exitCode == 0)
            #expect(
                !stopResult.stderr.contains("No active sessions to stop"),
                "session should have survived variants capture: \(stopResult.stderr)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Regression: previously, the CLI parser used a loose ERROR
    /// substring check that mis-bucketed any variant whose label
    /// happened to contain "ERROR" as a failure — silently dropping
    /// the image. Pin the label format so a variant labeled
    /// "ERROR_STATE" still captures successfully.
    @Test(
        "Label containing 'ERROR' is not mis-bucketed as failure",
        .timeLimit(.minutes(5))
    )
    func labelContainingErrorStillCapturesSuccessfully() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", #"{"colorScheme":"dark","label":"ERROR_STATE"}"#,
                    "-o", tempDir.path,
                    "--platform", "macos",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ]
            )

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("Captured 1/1 variants"),
                "stderr: \(result.stderr)"
            )
            try CLIRunner.assertValidJPEG(
                at: tempDir.appendingPathComponent("ERROR_STATE.jpg").path
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    // Local (pre-daemon) validation — jpeg quality, missing/unknown variant,
    // path-traversal/leading-dot/duplicate label, empty JSON variant —
    // moved to PreviewsCLITests/CLIValidationTests.swift, which invokes
    // VariantsCommand in-process instead of spawning a subprocess + daemon.
    // "Nonexistent file" stays here too, as a black-box smoke test: it's
    // the only remaining subprocess-level exitCode != 0 case for `variants`,
    // so the real compiled binary's dispatch-to-exit-code plumbing
    // (PreviewsMCPApp.swift) stays covered end-to-end for this subcommand,
    // matching touch/switch/configure/snapshot's kept "no session" tests.

    @Test("Nonexistent file returns non-zero exit")
    func nonexistentFile() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let result = try await CLIRunner.run(
                "variants",
                arguments: ["/nonexistent/file.swift", "--variant", "light"]
            )

            #expect(result.exitCode != 0, "Should fail with nonexistent file")
            #expect(result.stderr.contains("File not found"), "stderr: \(result.stderr)")
        }
    }
}

import Foundation
import Testing

@Suite("CLI variants command", .serialized)
struct VariantsCommandTests {

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        let home = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp")
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.sock"))
        try? FileManager.default.removeItem(at: home.appendingPathComponent("serve.pid"))
    }

    // MARK: - Happy paths

    @Test("Captures multiple presets to distinct files", .timeLimit(.minutes(2)))
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
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("Captured 2/2 variants"),
                "Expected success summary in stderr: \(result.stderr)")

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

    @Test("JSON variant uses custom label as filename", .timeLimit(.minutes(2)))
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
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            let outPath = tempDir.appendingPathComponent("my-custom-label.jpg").path
            try CLIRunner.assertValidJPEG(at: outPath)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    @Test("PNG format produces valid PNG files", .timeLimit(.minutes(2)))
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
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: tempDir.appendingPathComponent("light.png").path)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Happy path against an iOS simulator session. The macOS tests exercise
    /// the `App.host.session(for:)` + AppKit render path; this one exercises
    /// `iosState.getSession` + simulator screenshots, which is a separate
    /// branch in `handlePreviewVariants`. Gated on simulator availability.
    @Test(
        "Captures multiple presets against an iOS simulator session",
        .timeLimit(.minutes(5))
    )
    func capturesIOSVariants() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping iOS variants test")
                return
            }

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
                    "--platform", "ios",
                    "--project", CLIRunner.spmExampleRoot.path,
                    "--config", configPath,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("Captured 2/2 variants"),
                "stderr: \(result.stderr)"
            )
            try CLIRunner.assertValidJPEG(
                at: tempDir.appendingPathComponent("light.jpg").path)
            try CLIRunner.assertValidJPEG(
                at: tempDir.appendingPathComponent("dark.jpg").path)

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// When a session is already running for the target file, `variants`
    /// should reuse it rather than spinning up an ephemeral one. Observable
    /// proof: after the variants run, the session is still alive (stop
    /// --all reports it).
    @Test(
        "variants reuses an already-running session",
        .timeLimit(.minutes(2))
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
                ])
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
        .timeLimit(.minutes(2))
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
                ])

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

    // MARK: - Validation errors (local, no daemon required)

    @Test("--format jpeg with --quality 1.0 is rejected")
    func jpegQualityOneRejected() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file, "--variant", "light",
                    "--format", "jpeg", "--quality", "1.0",
                ])

            #expect(result.exitCode != 0)
            #expect(
                result.stderr.contains("--quality must be < 1.0 when --format jpeg"),
                "stderr: \(result.stderr)"
            )
        }
    }

    @Test("Missing --variant returns non-zero exit")
    func missingVariant() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run("variants", arguments: [file])

            #expect(result.exitCode != 0, "Should fail without --variant")
            #expect(
                result.stderr.contains("At least one --variant is required"),
                "stderr: \(result.stderr)")
        }
    }

    @Test("Invalid preset name returns non-zero exit and lists valid presets")
    func invalidPreset() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants", arguments: [file, "--variant", "neon"])

            #expect(result.exitCode != 0, "Should fail with invalid preset")
            #expect(
                result.stderr.contains("Unknown variant 'neon'"),
                "stderr should name the bad variant: \(result.stderr)")
            #expect(
                result.stderr.contains("light"),
                "stderr should list valid presets: \(result.stderr)")
        }
    }

    @Test("Path traversal in label is rejected")
    func pathTraversalLabelRejected() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", #"{"colorScheme":"dark","label":"../escape"}"#,
                    "-o", tempDir.path,
                ])

            #expect(result.exitCode != 0, "Should fail with path-traversal label")
            #expect(
                result.stderr.contains("Invalid variant label"),
                "stderr should explain rejection: \(result.stderr)")
        }
    }

    @Test("Leading-dot label is rejected")
    func leadingDotLabelRejected() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", #"{"colorScheme":"dark","label":".hidden"}"#,
                ])

            #expect(result.exitCode != 0, "Should reject hidden-file label")
            #expect(
                result.stderr.contains("cannot start with '.'"),
                "stderr: \(result.stderr)")
        }
    }

    @Test("Duplicate label is rejected with both indices")
    func duplicateLabelRejected() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [
                    file,
                    "--variant", "dark",
                    "--variant", #"{"colorScheme":"light","label":"dark"}"#,
                    "-o", tempDir.path,
                ])

            #expect(result.exitCode != 0, "Should reject duplicate label")
            #expect(
                result.stderr.contains("Duplicate variant label 'dark'"),
                "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("indices 0 and 1"),
                "stderr should name conflicting indices: \(result.stderr)")
        }
    }

    @Test("Empty JSON variant object is rejected")
    func emptyJsonVariantRejected() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "variants",
                arguments: [file, "--variant", "{}"])

            #expect(result.exitCode != 0, "Should reject empty JSON variant")
            #expect(
                result.stderr.contains("at least one trait"),
                "stderr: \(result.stderr)")
        }
    }

    @Test("Nonexistent file returns non-zero exit")
    func nonexistentFile() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let result = try await CLIRunner.run(
                "variants",
                arguments: ["/nonexistent/file.swift", "--variant", "light"])

            #expect(result.exitCode != 0, "Should fail with nonexistent file")
            #expect(result.stderr.contains("File not found"), "stderr: \(result.stderr)")
        }
    }
}

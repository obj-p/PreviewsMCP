import Foundation
import Testing

@Suite("CLI snapshot command", .serialized)
struct SnapshotCommandTests {

    // MARK: - macOS snapshot tests (SPM example)

    @Test("Basic macOS snapshot produces valid PNG", .timeLimit(.minutes(10)))
    func basicMacOSSnapshot() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(result.stdout.contains(outputPath), "stdout should print output path")
            try CLIRunner.assertValidPNG(
                at: outputPath, minSize: 10_000, expectedWidth: 400, expectedHeight: 600)
        }
    }

    @Test("Snapshot with --preview 1 produces different image", .timeLimit(.minutes(10)))
    func snapshotPreviewIndex1() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let output0 = tempDir.appendingPathComponent("preview0.png").path
            let output1 = tempDir.appendingPathComponent("preview1.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let project = CLIRunner.spmExampleRoot.path

            let result0 = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", output0, "--project", project,
                ])
            #expect(result0.exitCode == 0, "preview 0 stderr: \(result0.stderr)")

            let result1 = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", output1, "--preview", "1", "--project", project,
                ])
            #expect(result1.exitCode == 0, "preview 1 stderr: \(result1.stderr)")

            try CLIRunner.assertValidPNG(at: output0, minSize: 10_000)
            try CLIRunner.assertValidPNG(at: output1)

            let size0 = try Data(contentsOf: URL(fileURLWithPath: output0)).count
            let size1 = try Data(contentsOf: URL(fileURLWithPath: output1)).count
            #expect(
                size0 != size1,
                "Preview 0 (\(size0) bytes) and preview 1 (\(size1) bytes) should differ"
            )
        }
    }

    @Test("Snapshot with --color-scheme dark produces different image", .timeLimit(.minutes(10)))
    func snapshotDarkMode() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputLight = tempDir.appendingPathComponent("light.png").path
            let outputDark = tempDir.appendingPathComponent("dark.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let project = CLIRunner.spmExampleRoot.path

            let resultLight = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputLight, "--color-scheme", "light", "--project", project,
                ])
            #expect(resultLight.exitCode == 0, "light stderr: \(resultLight.stderr)")

            let resultDark = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputDark, "--color-scheme", "dark", "--project", project,
                ])
            #expect(resultDark.exitCode == 0, "dark stderr: \(resultDark.stderr)")

            try CLIRunner.assertValidPNG(at: outputLight)
            try CLIRunner.assertValidPNG(at: outputDark)

            let lightData = try Data(contentsOf: URL(fileURLWithPath: outputLight))
            let darkData = try Data(contentsOf: URL(fileURLWithPath: outputDark))
            #expect(lightData != darkData, "Light and dark snapshots should produce different images")
        }
    }

    @Test(
        "Snapshot with --dynamic-type-size accessibility3 produces image",
        .timeLimit(.minutes(10))
    )
    func snapshotDynamicTypeSize() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("a11y3.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath,
                    "--dynamic-type-size", "accessibility3",
                    "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    @Test("Snapshot with JPEG output produces valid JPEG", .timeLimit(.minutes(10)))
    func snapshotJPEGOutput() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.jpg").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidJPEG(at: outputPath)
        }
    }

    @Test("Snapshot of PreviewProvider file produces valid PNG", .timeLimit(.minutes(10)))
    func snapshotPreviewProvider() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("provider.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoProviderPreview.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    // MARK: - Error cases

    @Test("Snapshot with invalid --preview 99 returns non-zero exit", .timeLimit(.minutes(10)))
    func snapshotInvalidPreviewIndex() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("bad.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--preview", "99",
                    "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode != 0, "Should fail with invalid preview index")
            #expect(result.stderr.contains("Error"), "stderr should contain error message")
        }
    }

    @Test("Snapshot with invalid --dynamic-type-size returns non-zero exit")
    func snapshotInvalidDynamicTypeSize() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("bad.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--dynamic-type-size", "bananas",
                    "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode != 0, "Should fail with invalid dynamic type size")
        }
    }

    @Test("Snapshot of nonexistent file returns non-zero exit")
    func snapshotNonexistentFile() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("bad.png").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    "/nonexistent/file.swift", "-o", outputPath,
                ])

            #expect(result.exitCode != 0, "Should fail with nonexistent file")
        }
    }

    // MARK: - Build system tests (gated)

    @Test("Snapshot of xcodeproj example with --project", .timeLimit(.minutes(10)))
    func snapshotXcodeproj() async throws {
        try await DaemonTestLock.run {
            guard await CLIRunner.toolAvailable("mint") else {
                print("Mint not available — skipping xcodeproj snapshot test")
                return
            }

            // Generate Xcode project
            let genResult = try await CLIRunner.runExternal(
                "/usr/bin/env", arguments: ["mint", "run", "xcodegen", "generate"],
                workingDirectory: CLIRunner.xcodeprojExampleRoot
            )
            guard genResult.exitCode == 0 else {
                print("XcodeGen failed — skipping: \(genResult.stderr)")
                return
            }

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("xcodeproj.png").path
            let file = CLIRunner.xcodeprojExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.xcodeprojExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    @Test("Snapshot of xcworkspace example with --project", .timeLimit(.minutes(10)))
    func snapshotXcworkspace() async throws {
        try await DaemonTestLock.run {
            guard await CLIRunner.toolAvailable("mint") else {
                print("Mint not available — skipping xcworkspace snapshot test")
                return
            }

            let genResult = try await CLIRunner.runExternal(
                "/usr/bin/env", arguments: ["mint", "run", "xcodegen", "generate"],
                workingDirectory: CLIRunner.xcworkspaceExampleRoot
            )
            guard genResult.exitCode == 0 else {
                print("XcodeGen failed — skipping: \(genResult.stderr)")
                return
            }

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("xcworkspace.png").path
            let file = CLIRunner.xcworkspaceExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.xcworkspaceExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    @Test("Snapshot of Bazel example with --project", .timeLimit(.minutes(10)))
    func snapshotBazel() async throws {
        try await DaemonTestLock.run {
            var hasBazel = await CLIRunner.toolAvailable("bazelisk")
            if !hasBazel { hasBazel = await CLIRunner.toolAvailable("bazel") }
            guard hasBazel else {
                print("Bazel not available — skipping bazel snapshot test")
                return
            }

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("bazel.png").path
            let file = CLIRunner.bazelExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--project", CLIRunner.bazelExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    // MARK: - iOS snapshot (gated)

    @Test("Snapshot with --platform ios produces valid image", .timeLimit(.minutes(10)))
    func snapshotIOS() async throws {
        try await DaemonTestLock.run {
            let simResult = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available"]
            )
            guard simResult.exitCode == 0, simResult.stdout.contains("iPhone") else {
                print("No available iOS simulator — skipping iOS snapshot test")
                return
            }

            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("ios.png").path
            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    file, "-o", outputPath, "--platform", "ios",
                    "--project", CLIRunner.spmExampleRoot.path,
                ])

            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    /// Verifies the "magical reuse" behavior: when a `run` session is already
    /// live for the target file, `snapshot` captures *that* session's window
    /// instead of creating an ephemeral one. The observable proof is speed —
    /// reuse skips compile + render and completes in well under a second,
    /// whereas an ephemeral cold-start takes several seconds.
    @Test(
        "Snapshot reuses an already-running session instead of ephemeral",
        .timeLimit(.minutes(10))
    )
    func snapshotReusesLiveSession() async throws {
        try await DaemonTestLock.run {
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = CLIRunner.spmExampleRoot
                .appendingPathComponent("Sources/ToDo/ToDoView.swift").path
            let configPath = CLIRunner.repoRoot
                .appendingPathComponent("examples/.previewsmcp.json").path

            // Start a long-running session in the daemon.
            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    file, "--platform", "macos", "--config", configPath, "--detach",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            // Snapshot. Reuse should be fast because no compile is needed.
            let outputPath = tempDir.appendingPathComponent("reuse.png").path
            let start = Date()
            let snapResult = try await CLIRunner.run(
                "snapshot",
                arguments: [file, "-o", outputPath, "--platform", "macos"]
            )
            let elapsed = Date().timeIntervalSince(start)

            #expect(snapResult.exitCode == 0, "stderr: \(snapResult.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)

            // Ephemeral snapshots take several seconds (compile + render).
            // Reuse of a live session should complete in under 2 s on any
            // reasonable machine — generous bound to tolerate CI load.
            #expect(
                elapsed < 2.0,
                "snapshot should reuse live session (took \(elapsed)s; ephemeral would take >3s)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

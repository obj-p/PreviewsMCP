import Foundation
import Testing

@Suite("CLI variants command", .serialized)
struct VariantsCommandTests {

    // MARK: - Happy paths

    @Test("Captures multiple presets to distinct files", .timeLimit(.minutes(2)))
    func capturesMultiplePresets() async throws {
        let tempDir = try CLIRunner.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run(
            "variants",
            arguments: [
                file,
                "--variant", "light",
                "--variant", "dark",
                "-o", tempDir.path,
                "--project", CLIRunner.spmExampleRoot.path,
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
    }

    @Test("JSON variant uses custom label as filename", .timeLimit(.minutes(2)))
    func jsonVariantUsesCustomLabel() async throws {
        let tempDir = try CLIRunner.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run(
            "variants",
            arguments: [
                file,
                "--variant",
                #"{"colorScheme":"dark","dynamicTypeSize":"large","label":"my-custom-label"}"#,
                "-o", tempDir.path,
                "--project", CLIRunner.spmExampleRoot.path,
            ])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        let outPath = tempDir.appendingPathComponent("my-custom-label.jpg").path
        try CLIRunner.assertValidJPEG(at: outPath)
    }

    @Test("PNG format produces valid PNG files", .timeLimit(.minutes(2)))
    func pngFormat() async throws {
        let tempDir = try CLIRunner.makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run(
            "variants",
            arguments: [
                file,
                "--variant", "light",
                "--format", "png",
                "-o", tempDir.path,
                "--project", CLIRunner.spmExampleRoot.path,
            ])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        try CLIRunner.assertValidPNG(at: tempDir.appendingPathComponent("light.png").path)
    }

    // MARK: - Validation errors (exit 1)

    @Test("Missing --variant returns non-zero exit")
    func missingVariant() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run("variants", arguments: [file])

        #expect(result.exitCode != 0, "Should fail without --variant")
        #expect(
            result.stderr.contains("At least one --variant is required"),
            "stderr: \(result.stderr)")
    }

    @Test("Invalid preset name returns non-zero exit and lists valid presets")
    func invalidPreset() async throws {
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

    @Test("Path traversal in label is rejected")
    func pathTraversalLabelRejected() async throws {
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

    @Test("Leading-dot label is rejected")
    func leadingDotLabelRejected() async throws {
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

    @Test("Duplicate label is rejected with both indices")
    func duplicateLabelRejected() async throws {
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

    @Test("Empty JSON variant object is rejected")
    func emptyJsonVariantRejected() async throws {
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

    @Test("Nonexistent file returns non-zero exit")
    func nonexistentFile() async throws {
        let result = try await CLIRunner.run(
            "variants",
            arguments: ["/nonexistent/file.swift", "--variant", "light"])

        #expect(result.exitCode != 0, "Should fail with nonexistent file")
        #expect(result.stderr.contains("File not found"), "stderr: \(result.stderr)")
    }
}

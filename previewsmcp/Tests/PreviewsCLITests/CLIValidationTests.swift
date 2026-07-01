import ArgumentParser
import Foundation
@testable import PreviewsCLI
import Testing

/// Local (pre-daemon) argument validation for CLI subcommands. Each command
/// validates its own flags before ever calling `DaemonClient.withDaemonClient`,
/// so these run the `ParsableCommand` directly instead of spawning the CLI
/// binary and a daemon subprocess (that black-box coverage lives in
/// CLIIntegrationTests, alongside the no-session / happy-path tests that do
/// need a live daemon).
@Suite("CLI local validation")
struct CLIValidationTests {
    /// A real, always-present path to satisfy `FileManager.fileExists`
    /// checks in commands where a *different* validation is under test —
    /// its content is never read at the point these tests fail.
    /// `fileExists(atPath:)` doesn't distinguish files from directories, so
    /// the temp directory works without creating a fixture file.
    private static let existingFile = NSTemporaryDirectory()

    // MARK: - touch

    @Test("touch rejects partial swipe endpoints")
    func touchRejectsPartialSwipe() async throws {
        var command = try TouchCommand.parse(["100", "200", "--to-x", "300"])
        await expectValidationError(contains: "must be provided together") {
            try await command.run()
        }
    }

    @Test("touch rejects non-positive --duration")
    func touchRejectsNonPositiveDuration() async throws {
        var command = try TouchCommand.parse(
            ["100", "200", "--to-x", "300", "--to-y", "400", "--duration", "0"]
        )
        await expectValidationError(contains: "--duration must be positive") {
            try await command.run()
        }
    }

    @Test("touch rejects --duration without swipe endpoints")
    func touchRejectsDurationWithoutSwipe() async throws {
        var command = try TouchCommand.parse(["100", "200", "--duration", "0.5"])
        await expectValidationError(contains: "--duration only applies to swipes") {
            try await command.run()
        }
    }

    // MARK: - switch

    @Test("switch rejects a negative index")
    func switchRejectsNegativeIndex() async throws {
        var command = try SwitchCommand.parse(["--", "-1"])
        await expectValidationError(contains: "non-negative") {
            try await command.run()
        }
    }

    // MARK: - configure

    @Test("configure requires at least one trait flag")
    func configureRequiresAtLeastOneTrait() async throws {
        var command = try ConfigureCommand.parse([])
        await expectValidationError(contains: "No traits specified") {
            try await command.run()
        }
    }

    @Test("configure rejects an invalid color scheme")
    func configureRejectsInvalidTrait() async throws {
        var command = try ConfigureCommand.parse(["--color-scheme", "plaid"])
        await expectValidationError { message in
            message.lowercased().contains("color scheme")
        } run: {
            try await command.run()
        }
    }

    // MARK: - snapshot

    @Test("snapshot rejects an invalid --dynamic-type-size")
    func snapshotInvalidDynamicTypeSize() async throws {
        var command = try SnapshotCommand.parse([
            Self.existingFile, "--dynamic-type-size", "bananas",
        ])
        await expectValidationError(contains: "Invalid dynamic type size 'bananas'") {
            try await command.run()
        }
    }

    @Test("snapshot rejects a nonexistent file")
    func snapshotNonexistentFile() async throws {
        var command = try SnapshotCommand.parse(["/nonexistent/file.swift"])
        await expectValidationError(contains: "File not found") {
            try await command.run()
        }
    }

    // MARK: - variants

    @Test("variants rejects --format jpeg with --quality 1.0")
    func variantsJPEGQualityOneRejected() async throws {
        var command = try VariantsCommand.parse([
            Self.existingFile, "--variant", "light", "--format", "jpeg", "--quality", "1.0",
        ])
        await expectValidationError(contains: "--quality must be < 1.0 when --format jpeg") {
            try await command.run()
        }
    }

    @Test("variants requires at least one --variant")
    func variantsMissingVariant() async throws {
        var command = try VariantsCommand.parse(["irrelevant.swift"])
        await expectValidationError(contains: "At least one --variant is required") {
            try await command.run()
        }
    }

    @Test("variants rejects an unknown preset and lists valid presets")
    func variantsInvalidPreset() async throws {
        var command = try VariantsCommand.parse([Self.existingFile, "--variant", "neon"])
        await expectValidationError { message in
            message.contains("Unknown variant 'neon'") && message.contains("light")
        } run: {
            try await command.run()
        }
    }

    @Test("variants rejects a path-traversal label")
    func variantsPathTraversalLabelRejected() async throws {
        var command = try VariantsCommand.parse([
            Self.existingFile, "--variant", #"{"colorScheme":"dark","label":"../escape"}"#,
        ])
        await expectValidationError(contains: "Invalid variant label") {
            try await command.run()
        }
    }

    @Test("variants rejects a leading-dot label")
    func variantsLeadingDotLabelRejected() async throws {
        var command = try VariantsCommand.parse([
            Self.existingFile, "--variant", #"{"colorScheme":"dark","label":".hidden"}"#,
        ])
        await expectValidationError(contains: "cannot start with '.'") {
            try await command.run()
        }
    }

    @Test("variants rejects a duplicate label with both indices")
    func variantsDuplicateLabelRejected() async throws {
        var command = try VariantsCommand.parse([
            Self.existingFile,
            "--variant", "dark",
            "--variant", #"{"colorScheme":"light","label":"dark"}"#,
        ])
        await expectValidationError { message in
            message.contains("Duplicate variant label 'dark'")
                && message.contains("indices 0 and 1")
        } run: {
            try await command.run()
        }
    }

    @Test("variants rejects an empty JSON variant object")
    func variantsEmptyJSONVariantRejected() async throws {
        var command = try VariantsCommand.parse([Self.existingFile, "--variant", "{}"])
        await expectValidationError(contains: "at least one trait") {
            try await command.run()
        }
    }

    @Test("variants rejects a nonexistent file")
    func variantsNonexistentFile() async throws {
        var command = try VariantsCommand.parse([
            "/nonexistent/file.swift", "--variant", "light",
        ])
        await expectValidationError(contains: "File not found") {
            try await command.run()
        }
    }
}

/// Runs `run`, expecting it to throw a `ValidationError` matching `predicate`.
/// Records an `Issue` (rather than letting the caller's own `throws` bubble
/// up) so a wrong-error-type failure reports the mismatch instead of
/// crashing out of the test with an unrelated stack trace.
private func expectValidationError(
    predicate: (String) -> Bool = { _ in true },
    run: () async throws -> Void
) async {
    do {
        try await run()
        Issue.record("expected a ValidationError, but run() succeeded")
    } catch let error as ValidationError {
        #expect(predicate(error.message), "unexpected message: \(error.message)")
    } catch {
        Issue.record("expected a ValidationError, got \(error)")
    }
}

private func expectValidationError(
    contains substring: String,
    run: () async throws -> Void
) async {
    await expectValidationError(predicate: { $0.contains(substring) }, run: run)
}

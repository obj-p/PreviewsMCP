import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `variants`'s CLI-side logic, tested without a real daemon or renderer.
///
/// Every test in `CLIIntegrationTests/VariantsCommandTests.swift` exercises
/// real rendering or real build-system behavior — none of that is
/// convertible here. `VariantsCommand.exitCode(successCount:failCount:)` is
/// already unit-tested directly in `VariantsExitCodeTests.swift`. What's
/// covered here: the previously-untested `resolvedQuality()`,
/// `captureEphemeral`'s cleanup-on-throw path (mirrors
/// `SnapshotCommand.snapshotEphemeral`'s equivalent test) — genuine
/// daemon-relay logic no integration test reaches, since forcing a
/// mid-flow `preview_variants` failure after a real session already
/// started would require injecting a daemon-side fault — and
/// `captureVariants`' missing-`structuredContent` guard. Unlike
/// `SnapshotCommand`, `captureVariants` has no top-level daemon-`isError`
/// check at all: per-variant failures are reported via each outcome's
/// `status` field inside `structuredContent`, not a response-level flag.
@Suite("variants CLI-glue logic")
struct VariantsCommandLogicTests {
    // MARK: - resolvedQuality

    @Test("resolvedQuality: --format png always requests 1.0")
    func pngFormatForcesMaxQuality() throws {
        let command = try VariantsCommand.parse(["a.swift", "--variant", "light", "--format", "png"])
        #expect(command.resolvedQuality() == 1.0)
    }

    @Test("resolvedQuality: explicit --quality wins for jpeg")
    func explicitQualityWins() throws {
        let command = try VariantsCommand.parse([
            "a.swift", "--variant", "light", "--quality", "0.5",
        ])
        #expect(command.resolvedQuality() == 0.5)
    }

    @Test("resolvedQuality: defaults to 0.85 for jpeg with no --quality")
    func jpegDefaultsTo085() throws {
        let command = try VariantsCommand.parse(["a.swift", "--variant", "light"])
        #expect(command.resolvedQuality() == 0.85)
    }

    // MARK: - captureEphemeral cleanup-on-throw

    @Test("captureEphemeral stops the session it started even when the capture call fails")
    func ephemeralSessionStoppedAfterCaptureFailure() async throws {
        let command = try VariantsCommand.parse(["a.swift", "--variant", "light"])
        let startResult = try CallTool.Result.ephemeralStartResult()
        // preview_variants is deliberately unscripted — FakeDaemonClient
        // throws for it, simulating a mid-flow daemon failure after the
        // session already started. preview_stop IS scripted so the
        // assertion below proves cleanup actually succeeds.
        let client = FakeDaemonClient(responses: [
            "preview_start": startResult,
            "preview_stop": CallTool.Result(content: []),
        ])

        await #expect(throws: FakeDaemonClientError.self) {
            _ = try await command.captureEphemeral(
                file: "/nonexistent/previewsmcp-logic-test/File.swift",
                labels: ["light"],
                outputDir: URL(fileURLWithPath: "/tmp"),
                client: client
            )
        }

        #expect(client.calls.map(\.name) == ["preview_start", "preview_variants", "preview_stop"])
        #expect(client.calls.last?.arguments?["sessionID"] == .string("test-session"))
    }

    // MARK: - captureVariants

    @Test("captureVariants errors when the response has no structuredContent")
    func captureVariantsMissingStructuredContent() async throws {
        let command = try VariantsCommand.parse(["a.swift", "--variant", "light"])
        let client = FakeDaemonClient(responses: [
            "preview_variants": CallTool.Result(content: [.text("no structured payload")]),
        ])

        await expectDaemonToolError(contains: "missing structuredContent") {
            _ = try await command.captureVariants(
                sessionID: "test-session",
                labels: ["light"],
                outputDir: URL(fileURLWithPath: "/tmp"),
                client: client
            )
        }
    }
}

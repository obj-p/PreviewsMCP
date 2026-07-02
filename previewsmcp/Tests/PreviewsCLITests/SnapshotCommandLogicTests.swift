import Foundation
import MCP
@testable import PreviewsCLI
import PreviewsCore
import Testing

/// `snapshot`'s CLI-side logic, tested without a real daemon or renderer.
///
/// Every test in `CLIIntegrationTests/SnapshotCommandTests.swift` exercises
/// real rendering or real build-system behavior (PNG/JPEG validity,
/// generated-source handling, live-session reuse) — none of that is
/// convertible here. What *is* covered: the two previously-untested pure
/// helpers (`resolvedQuality`, `resolvePlatform`), and `snapshotEphemeral`'s
/// cleanup-on-throw path, which no integration test reaches (the only
/// error case there, an out-of-range `--preview` index, is rejected by
/// `preview_start` itself, never by the mid-flow `preview_snapshot` call).
@Suite("snapshot CLI-glue logic")
struct SnapshotCommandLogicTests {
    // MARK: - resolvedQuality

    @Test("resolvedQuality: explicit --quality wins over the output extension")
    func explicitQualityWins() throws {
        let command = try SnapshotCommand.parse(["a.swift", "-o", "out.png", "--quality", "0.5"])
        #expect(command.resolvedQuality() == 0.5)
    }

    @Test("resolvedQuality: .png output defaults to 1.0")
    func pngDefaultsToMaxQuality() throws {
        let command = try SnapshotCommand.parse(["a.swift", "-o", "out.png"])
        #expect(command.resolvedQuality() == 1.0)
    }

    @Test("resolvedQuality: .jpg/.jpeg output defaults to 0.85")
    func jpegDefaultsTo085() throws {
        let jpg = try SnapshotCommand.parse(["a.swift", "-o", "out.jpg"])
        let jpeg = try SnapshotCommand.parse(["a.swift", "-o", "out.jpeg"])
        #expect(jpg.resolvedQuality() == 0.85)
        #expect(jpeg.resolvedQuality() == 0.85)
    }

    @Test("resolvedQuality: an unrecognized extension falls back to 0.85")
    func unknownExtensionDefaultsTo085() throws {
        let command = try SnapshotCommand.parse(["a.swift", "-o", "out.bmp"])
        #expect(command.resolvedQuality() == 0.85)
    }

    // MARK: - resolvePlatform

    /// A source path with no real SPM package around it, so
    /// `SPMBuildSystem.inferredPlatform` reliably returns `nil` — isolates
    /// the explicit/config precedence from real file-system inference.
    /// The inference-returns-`.iOS` branch itself has no coverage, direct
    /// or indirect: the only real SPM fixture (`examples/spm`) declares
    /// both macOS and iOS platforms, and `inferredPlatform` only returns
    /// `.iOS` for iOS-*only* packages, so no existing test drives it.
    private static let noInferenceFile = URL(
        fileURLWithPath: "/nonexistent/previewsmcp-logic-test/File.swift"
    )

    /// `ProjectConfig`'s memberwise init is internal despite its properties
    /// being public, so tests build one via its `Codable` conformance
    /// instead of reaching for `@testable import PreviewsCore`.
    private static func projectConfig(platform: String) throws -> ProjectConfig {
        try JSONDecoder().decode(
            ProjectConfig.self,
            from: Data(#"{"platform": "\#(platform)"}"#.utf8)
        )
    }

    @Test("resolvePlatform: explicit flag wins over everything")
    func explicitPlatformWins() throws {
        let resolved = SnapshotCommand.resolvePlatform(
            explicit: .ios,
            config: try Self.projectConfig(platform: "macos"),
            project: nil,
            fileURL: Self.noInferenceFile
        )
        #expect(resolved == .ios)
    }

    @Test("resolvePlatform: config platform wins when no explicit flag is set")
    func configPlatformWins() throws {
        let resolved = SnapshotCommand.resolvePlatform(
            explicit: nil,
            config: try Self.projectConfig(platform: "ios"),
            project: nil,
            fileURL: Self.noInferenceFile
        )
        #expect(resolved == .ios)
    }

    @Test("resolvePlatform: falls back to macos with no explicit flag, config, or inference")
    func defaultsToMacOS() {
        let resolved = SnapshotCommand.resolvePlatform(
            explicit: nil,
            config: nil,
            project: nil,
            fileURL: Self.noInferenceFile
        )
        #expect(resolved == .macos)
    }

    // MARK: - snapshotEphemeral cleanup-on-throw

    @Test("snapshotEphemeral stops the session it started even when the snapshot call fails")
    func ephemeralSessionStoppedAfterSnapshotFailure() async throws {
        let command = try SnapshotCommand.parse([
            "/nonexistent/previewsmcp-logic-test/File.swift", "--platform", "macos",
        ])
        let startResult = try CallTool.Result.ephemeralStartResult()
        // preview_snapshot is deliberately unscripted — FakeDaemonClient
        // throws for it, simulating a mid-flow daemon failure after the
        // session already started. preview_stop IS scripted so the
        // assertion below proves cleanup actually succeeds, not just that
        // it was attempted.
        let client = FakeDaemonClient(responses: [
            "preview_start": startResult,
            "preview_stop": CallTool.Result(content: []),
        ])

        await #expect(throws: FakeDaemonClientError.self) {
            try await command.snapshotEphemeral(
                file: "/nonexistent/previewsmcp-logic-test/File.swift", client: client
            )
        }

        #expect(client.calls.map(\.name) == ["preview_start", "preview_snapshot", "preview_stop"])
        #expect(client.calls.last?.arguments?["sessionID"] == .string("test-session"))
    }
}

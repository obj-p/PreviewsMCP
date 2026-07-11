import Foundation
import MCP
@testable import PreviewsCLI
import PreviewsCore
import Testing

/// `snapshot-all`'s CLI-side orchestration, tested without a real daemon or
/// renderer. Discovery (`PreviewParser`) and file writing are real — only the
/// daemon tool calls are faked — so these cover the batch loop, iOS gating,
/// per-slot failure handling, the manifest, and the HTML gallery end to end
/// at millisecond speed. Real rendering / PNG validity lives in
/// `CLIIntegrationTests/SnapshotAllCommandTests.swift`.
@Suite("snapshot-all CLI-glue logic")
struct SnapshotAllCommandLogicTests {
    // MARK: - Pure helpers

    @Test("VariantPlan comma-splits bare tokens but keeps JSON variants whole")
    func variantPlanSplitting() throws {
        let bare = try VariantPlan.resolve(from: ["light,dark"])
        #expect(bare.labels == ["light", "dark"])

        let json = try VariantPlan.resolve(from: [
            #"{"colorScheme":"dark","locale":"ar","label":"dark-ar"}"#,
        ])
        #expect(json.labels == ["dark-ar"])
    }

    @Test("VariantPlan rejects duplicate labels")
    func variantPlanDuplicateLabel() {
        #expect(throws: (any Error).self) {
            _ = try VariantPlan.resolve(from: ["light,light"])
        }
    }

    @Test("slug is relative to the walked root so images never collide")
    func slugRelativeToRoot() {
        #expect(
            SnapshotAllCommand.slug(for: "/proj/Sources/ToDo/View.swift", root: "/proj")
                == "Sources_ToDo_View"
        )
        // A file target uses its parent as root, so just the basename remains.
        #expect(
            SnapshotAllCommand.slug(for: "/proj/Sources/View.swift", root: "/proj/Sources")
                == "View"
        )
    }

    @Test("resolvedQuality: png → 1.0, jpeg → explicit or 0.85")
    func resolvedQuality() throws {
        #expect(try SnapshotAllCommand.parse(["--format", "png"]).resolvedQuality() == 1.0)
        #expect(try SnapshotAllCommand.parse(["--format", "jpeg"]).resolvedQuality() == 0.85)
        #expect(
            try SnapshotAllCommand.parse(["--format", "jpeg", "--quality", "0.5"])
                .resolvedQuality() == 0.5
        )
    }

    // MARK: - Orchestration

    @Test("renders one image per preview and writes a matching manifest")
    func batchNoVariants() async throws {
        let env = try Fixture(previewCount: 2)
        defer { env.cleanup() }
        let client = FakeDaemonClient(responses: [
            "preview_start": try CallTool.Result.ephemeralStartResult(),
            "preview_switch": CallTool.Result(content: []),
            "preview_snapshot": Self.imageResult(),
            "preview_stop": CallTool.Result(content: []),
        ])

        let code = try await env.command.execute(on: client, plan: try VariantPlan.resolve(from: []))
        #expect(code == 0)

        let manifest = try env.manifest()
        #expect(manifest.previewCount == 2)
        #expect(manifest.imageCount == 2)
        #expect(manifest.errorCount == 0)
        #expect(manifest.entries.count == 2)
        #expect(manifest.entries.allSatisfy { $0.status == "ok" && $0.variant == nil })
        for entry in manifest.entries {
            let image = try #require(entry.image)
            #expect(FileManager.default.fileExists(atPath: env.out.appendingPathComponent(image).path))
        }
        // One session for the file: start, one switch (index 0→1), two
        // snapshots, one stop.
        #expect(client.calls.map(\.name) == [
            "preview_start", "preview_snapshot", "preview_switch", "preview_snapshot", "preview_stop",
        ])
    }

    @Test("--variants multiplies outputs and --html references every image")
    func batchVariantsAndGallery() async throws {
        let env = try Fixture(previewCount: 1, extraArgs: ["--variants", "light,dark", "--html"])
        defer { env.cleanup() }
        let plan = try VariantPlan.resolve(from: env.command.variants)
        let client = FakeDaemonClient(responses: [
            "preview_start": try CallTool.Result.ephemeralStartResult(),
            "preview_variants": try Self.variantsResult(labels: ["light", "dark"]),
            "preview_stop": CallTool.Result(content: []),
        ])

        let code = try await env.command.execute(on: client, plan: plan)
        #expect(code == 0)

        let manifest = try env.manifest()
        #expect(manifest.previewCount == 1)
        #expect(manifest.imageCount == 2)
        #expect(manifest.entries.count == 2)
        #expect(Set(manifest.entries.compactMap(\.variant)) == ["light", "dark"])

        let gallery = try String(
            contentsOf: env.out.appendingPathComponent("index.html"), encoding: .utf8
        )
        for entry in manifest.entries {
            let image = try #require(entry.image)
            #expect(gallery.contains(image))
        }
    }

    @Test("iOS-resolved previews are skipped without touching the daemon")
    func iosGated() async throws {
        let env = try Fixture(previewCount: 2, extraArgs: ["--platform", "ios"])
        defer { env.cleanup() }
        let client = FakeDaemonClient()

        let code = try await env.command.execute(on: client, plan: try VariantPlan.resolve(from: []))
        // All skipped → nothing failed → exit 0.
        #expect(code == 0)
        #expect(client.calls.isEmpty, "no simulator/daemon work for gated iOS previews")

        let manifest = try env.manifest()
        #expect(manifest.previewCount == 2)
        #expect(manifest.skippedCount == 2)
        #expect(manifest.imageCount == 0)
        #expect(manifest.entries.allSatisfy { $0.status == "skipped" && $0.image == nil })
    }

    @Test("one failed render is recorded and the batch continues (partial exit)")
    func partialFailureContinues() async throws {
        let env = try Fixture(previewCount: 2)
        defer { env.cleanup() }
        // Preview 0 snapshots fine; preview 1's snapshot fails. The batch must
        // still finish preview 0 and stop the session.
        let client = FakeDaemonClient(
            responses: [
                "preview_start": try CallTool.Result.ephemeralStartResult(),
                "preview_switch": CallTool.Result(content: []),
                "preview_stop": CallTool.Result(content: []),
            ],
            sequences: [
                "preview_snapshot": [
                    Self.imageResult(),
                    CallTool.Result(content: [.text("render failed")], isError: true),
                ],
            ]
        )

        let code = try await env.command.execute(on: client, plan: try VariantPlan.resolve(from: []))
        #expect(code == 1, "partial failure → exit 1")

        let manifest = try env.manifest()
        #expect(manifest.imageCount == 1)
        #expect(manifest.errorCount == 1)
        #expect(client.calls.contains { $0.name == "preview_stop" }, "session stopped despite failure")
    }

    // MARK: - Fixtures

    /// A source file with `count` `#Preview` blocks, plus an output dir and a
    /// parsed command pointed at both. Real files so `PreviewParser` discovers
    /// real previews.
    private struct Fixture {
        let command: SnapshotAllCommand
        let out: URL
        private let root: URL

        init(previewCount count: Int, extraArgs: [String] = []) throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("snapshot-all-logic-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let source = root.appendingPathComponent("Views.swift")
            let blocks = (0 ..< count)
                .map { "#Preview(\"P\($0)\") { Text(\"\($0)\") }" }
                .joined(separator: "\n")
            try Data("import SwiftUI\n\(blocks)\n".utf8).write(to: source)
            out = root.appendingPathComponent("out")

            command = try SnapshotAllCommand.parse(
                [source.path, "--out", out.path, "--platform", "macos"] + extraArgs
            )
        }

        func manifest() throws -> DecodedManifest {
            let data = try Data(contentsOf: out.appendingPathComponent("manifest.json"))
            return try JSONDecoder().decode(DecodedManifest.self, from: data)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
        }
    }

    private struct DecodedManifest: Decodable {
        let previewCount: Int
        let imageCount: Int
        let skippedCount: Int
        let errorCount: Int
        let entries: [Entry]

        struct Entry: Decodable {
            let index: Int
            let variant: String?
            let image: String?
            let status: String
        }
    }

    // MARK: - Canned daemon responses

    private static func imageResult() -> CallTool.Result {
        CallTool.Result(content: [
            .image(data: Data("x".utf8).base64EncodedString(), mimeType: "image/png", metadata: nil),
        ])
    }

    /// A `preview_variants` response: one `.image` block and one `ok` outcome
    /// per label, mirroring how `PreviewVariantsHandler` packs them.
    private static func variantsResult(labels: [String]) throws -> CallTool.Result {
        let content: [Tool.Content] = labels.map { _ in
            .image(data: Data("x".utf8).base64EncodedString(), mimeType: "image/png", metadata: nil)
        }
        let outcomes = labels.enumerated().map { index, label in
            DaemonProtocol.VariantOutcomeDTO(
                status: "ok", index: index, label: label, imageIndex: index, error: nil
            )
        }
        let structured = DaemonProtocol.VariantsResult(
            variants: outcomes, successCount: labels.count, failCount: 0
        )
        return try CallTool.Result(content: content, structuredContent: structured)
    }
}

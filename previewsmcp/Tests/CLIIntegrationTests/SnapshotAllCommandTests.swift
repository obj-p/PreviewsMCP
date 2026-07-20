import Foundation
import PreviewsTestSupport
import Testing

/// End-to-end coverage for `snapshot-all`: batch-render every `#Preview` in a
/// target headless, writing an image per (preview × variant), a JSON
/// manifest, and an optional static HTML gallery.
///
/// Targets a single source file (`ToDoView.swift`, two macOS `#Preview`
/// blocks) rather than the whole `examples/spm` tree. That keeps the run
/// deterministic and cheap — one compile plus one cheap index switch — and
/// avoids the tree's UIKit-only / LocalDep-dependent previews, which don't
/// render on headless macOS. The directory-walk and per-file orchestration
/// logic is covered exhaustively (and without a real renderer) by
/// `PreviewsCLITests/SnapshotAllCommandLogicTests.swift`.
@Suite("CLI snapshot-all command", .serialized)
struct SnapshotAllCommandTests {
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    /// The manifest's `entries` array is the backbone: one per rendered
    /// (preview × variant) slot. Only the fields the tests assert on are
    /// decoded.
    private struct Manifest: Decodable {
        let version: Int
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

    private static func loadManifest(in outDir: URL) throws -> Manifest {
        let data = try Data(contentsOf: outDir.appendingPathComponent("manifest.json"))
        return try JSONDecoder().decode(Manifest.self, from: data)
    }

    private static let toDoView = CLIRunner.spmExampleRoot
        .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

    // MARK: - Base batch render

    @Test("snapshot-all renders one image per discovered preview", .timeLimit(.minutes(10)))
    func batchRendersEveryPreview() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let outDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: outDir) }

            let result = try await CLIRunner.run(
                "snapshot-all",
                arguments: [
                    Self.toDoView, "--out", outDir.path,
                    "--project", CLIRunner.spmExampleRoot.path, "--format", "png",
                ]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let manifest = try Self.loadManifest(in: outDir)
            #expect(manifest.version == 1, "manifest carries a schema version")
            // ToDoView.swift declares exactly two #Preview blocks.
            #expect(manifest.previewCount == 2, "expected 2 discovered previews")
            #expect(manifest.imageCount == 2)
            #expect(manifest.skippedCount == 0)
            #expect(manifest.errorCount == 0)
            #expect(manifest.entries.count == 2)
            #expect(Set(manifest.entries.map(\.index)) == [0, 1])

            for entry in manifest.entries {
                #expect(entry.status == "ok")
                #expect(entry.variant == nil)
                // Every manifest image path must resolve to a real PNG on disk.
                let image = try #require(entry.image)
                try CLIRunner.assertValidPNG(at: outDir.appendingPathComponent(image).path)
            }
        }
    }

    // MARK: - Variants multiply outputs + HTML gallery

    @Test("snapshot-all --variants multiplies outputs and --html emits a gallery", .timeLimit(.minutes(10)))
    func variantsAndGallery() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let outDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: outDir) }

            let result = try await CLIRunner.run(
                "snapshot-all",
                arguments: [
                    Self.toDoView, "--out", outDir.path,
                    "--variants", "light,dark", "--html", "--format", "png",
                    "--project", CLIRunner.spmExampleRoot.path,
                ]
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let manifest = try Self.loadManifest(in: outDir)
            // Two previews × two variants (light, dark) = four images; the
            // discovered-preview count stays two.
            #expect(manifest.previewCount == 2)
            #expect(manifest.imageCount == 4)
            #expect(manifest.entries.count == 4)
            #expect(Set(manifest.entries.compactMap(\.variant)) == ["light", "dark"])

            for entry in manifest.entries {
                #expect(entry.status == "ok")
                let image = try #require(entry.image)
                try CLIRunner.assertValidPNG(at: outDir.appendingPathComponent(image).path)
            }

            // The gallery is a self-contained static HTML file that references
            // every rendered image by its manifest-relative path.
            let galleryURL = outDir.appendingPathComponent("index.html")
            let gallery = try String(contentsOf: galleryURL, encoding: .utf8)
            for entry in manifest.entries {
                let image = try #require(entry.image)
                #expect(gallery.contains(image), "gallery should reference \(image)")
            }
        }
    }
}

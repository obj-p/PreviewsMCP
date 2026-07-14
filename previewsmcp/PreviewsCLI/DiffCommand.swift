import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsImageDiff

/// The machine-readable diff result, shared by the `diff` CLI (`--json`)
/// and the `preview_diff` MCP tool (`structuredContent`). `diffImage` is
/// the written PNG path for the CLI; nil for the MCP tool, which returns
/// the diff image as an inline content block instead.
struct DiffReport: Codable {
    let similarity: Double
    let changedPixelCount: Int
    let totalPixelCount: Int
    let changedRegions: [DiffRegion]
    let sizeMismatch: SizeMismatch?
    let diffImage: String?

    init(_ result: ImageDiffResult, diffImage: String? = nil) {
        similarity = result.similarity
        changedPixelCount = result.changedPixelCount
        totalPixelCount = result.totalPixelCount
        changedRegions = result.changedRegions
        sizeMismatch = result.sizeMismatch
        self.diffImage = diffImage
    }
}

/// Compare two preview snapshots and report how much they changed.
///
/// A pure, local command — it reads two image files, pixel-compares them,
/// and optionally writes a diff image. There is no daemon roundtrip, so it
/// works on any PNG/JPEG, not only images this tool produced.
struct DiffCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "diff",
        abstract: "Compare two preview snapshots; report a similarity score and write a diff image",
        discussion: """
        Pixel-compares two images and prints a similarity score (0.0–1.0),
        the number of changed pixels, and the bounding box of the change.
        Pass --output to also write a diff image: changed pixels in red over
        a dimmed copy of the second image.

        Tolerance is per-channel (0–255) and defaults to 8, because two
        renders of the same view are not bit-identical (anti-aliasing, font
        hinting). Raise it to absorb more noise, or set 0 for an exact
        comparison.
        """
    )

    @Argument(help: "Baseline image path (PNG or JPEG)", transform: Path.normalize)
    var baseline: String

    @Argument(help: "Current image path (PNG or JPEG)", transform: Path.normalize)
    var current: String

    @Option(name: [.short, .long], help: "Write the diff image (PNG) to this path")
    var output: String?

    @Option(name: .long, help: "Per-channel tolerance 0–255 (default: 8)")
    var tolerance: Int = ImageDiff.defaultTolerance

    @Flag(help: "Emit machine-readable JSON")
    var json = false

    func run() throws {
        guard (0 ... 255).contains(tolerance) else {
            throw ValidationError("Tolerance must be between 0 and 255.")
        }

        let result = try ImageDiff.compare(
            baselineAt: URL(fileURLWithPath: baseline),
            currentAt: URL(fileURLWithPath: current),
            tolerance: tolerance,
            renderDiff: output != nil
        )

        var diffImagePath: String?
        if let output, let diffImage = result.diffImage {
            let url = URL(fileURLWithPath: output)
            try diffImage.pngData().write(to: url)
            diffImagePath = url.path
        }

        if json {
            try emitJSON(DiffReport(result, diffImage: diffImagePath))
        } else {
            emitText(result, diffImagePath: diffImagePath)
        }
    }

    private func emitText(_ result: ImageDiffResult, diffImagePath: String?) {
        if let mismatch = result.sizeMismatch {
            print(
                "size mismatch: baseline \(mismatch.baseline), current \(mismatch.current) "
                    + "— cannot pixel-compare"
            )
            return
        }
        let percent = String(format: "%.2f", result.similarity * 100)
        print("similarity: \(percent)% (\(result.changedPixelCount)/\(result.totalPixelCount) pixels changed)")
        if let region = result.changedRegions.first {
            print("changed region: x=\(region.x) y=\(region.y) \(region.width)x\(region.height)")
        }
        if let diffImagePath {
            print("diff image: \(diffImagePath)")
        }
    }
}

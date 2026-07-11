import Foundation
import MCP
import PreviewsImageDiff

/// `preview_diff` — pixel-compare two snapshot images and return a
/// similarity score plus a diff image. This is the agent feedback loop:
/// snapshot before, edit, snapshot after, ask "did it land?".
///
/// Pure and path-based: it reads two image files directly rather than
/// resolving a session, so there is no daemon roundtrip.
enum PreviewDiffHandler: ToolHandler {
    static let name: ToolName = .previewDiff

    static let schema = Tool(
        name: ToolName.previewDiff.rawValue,
        description:
        "Compare two snapshot images. Returns a similarity score (0.0–1.0), the changed-pixel count and region, and a diff image highlighting changed pixels in red.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "baseline": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the baseline image (PNG or JPEG)"),
                ]),
                "current": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to the current image (PNG or JPEG)"),
                ]),
                "tolerance": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "Per-channel tolerance 0–255 (default: 8). A pixel differs when any channel exceeds this; nonzero absorbs anti-aliasing and font-hinting noise."
                    ),
                ]),
            ]),
            "required": .array([.string("baseline"), .string("current")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx _: HandlerContext
    ) async throws -> CallTool.Result {
        let baselinePath: String
        let currentPath: String
        do {
            baselinePath = try extractString("baseline", from: params)
            currentPath = try extractString("current", from: params)
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }
        let tolerance = extractOptionalInt("tolerance", from: params) ?? ImageDiff.defaultTolerance

        let result: ImageDiffResult
        do {
            result = try ImageDiff.compare(
                baselineAt: URL(fileURLWithPath: baselinePath),
                currentAt: URL(fileURLWithPath: currentPath),
                tolerance: tolerance
            )
        } catch {
            return CallTool.Result(
                content: [.text("Diff failed: \(error.localizedDescription)")],
                isError: true
            )
        }

        if let mismatch = result.sizeMismatch {
            return try CallTool.Result(
                content: [.text(
                    "Size mismatch: baseline is \(mismatch.baseline), current is \(mismatch.current). "
                        + "Images must share dimensions to pixel-compare."
                )],
                structuredContent: DiffReport(result)
            )
        }

        var content: [Tool.Content] = [
            .text(summary(for: result)),
        ]
        if let diffImage = result.diffImage, let data = try? diffImage.pngData() {
            content.append(.image(data: data.base64EncodedString(), mimeType: "image/png", metadata: nil))
        }
        return try CallTool.Result(content: content, structuredContent: DiffReport(result))
    }

    private static func summary(for result: ImageDiffResult) -> String {
        let percent = String(format: "%.2f", result.similarity * 100)
        var line = "similarity \(percent)% (\(result.changedPixelCount)/\(result.totalPixelCount) pixels changed)"
        if let region = result.changedRegions.first {
            line += "; changed region x=\(region.x) y=\(region.y) \(region.width)x\(region.height)"
        }
        return line
    }
}

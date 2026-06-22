import Foundation
import MCP

enum PreviewSnapshotHandler: ToolHandler {
    static let name: ToolName = .previewSnapshot

    static let schema = Tool(
        name: ToolName.previewSnapshot.rawValue,
        description:
            "Capture a screenshot of a running preview. Returns the image as JPEG (default) or PNG.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from preview_start"),
                ]),
                "quality": .object([
                    "type": .string("number"),
                    "description": .string(
                        "JPEG quality 0.0–1.0 (default: 0.85). Values >= 1.0 produce PNG output."
                    ),
                ]),
            ]),
            "required": .array([.string("sessionID")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let sessionID: String
        do { sessionID = try extractString("sessionID", from: params) } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        let configQuality = await configQualityForSession(sessionID, ctx: ctx)
        let quality = max(0.0, min(1.0, extractOptionalDouble("quality", from: params) ?? configQuality ?? 0.85))
        let mimeType = quality >= 1.0 ? "image/png" : "image/jpeg"

        guard let handle = await ctx.router.handle(for: sessionID) else {
            return CallTool.Result(
                content: [.text("No session found for \(sessionID).")],
                isError: true
            )
        }

        let imageData = try await handle.snapshot(quality: quality)
        let base64 = imageData.base64EncodedString()

        return CallTool.Result(content: [
            .image(data: base64, mimeType: mimeType, metadata: nil)
        ])
    }
}

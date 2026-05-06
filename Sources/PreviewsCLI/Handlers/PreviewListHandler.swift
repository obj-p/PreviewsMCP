import Foundation
import MCP
import PreviewsCore

enum PreviewListHandler: ToolHandler {
    static let name: ToolName = .previewList

    static let schema = Tool(
        name: ToolName.previewList.rawValue,
        description: "List #Preview blocks in a Swift source file",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "filePath": .object([
                    "type": .string("string"),
                    "description": .string("Absolute path to a Swift source file"),
                ])
            ]),
            "required": .array([.string("filePath")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let filePath: String
        do { filePath = try extractString("filePath", from: params) } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        let fileURL = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            return CallTool.Result(content: [.text("File not found: \(filePath)")], isError: true)
        }

        let previews = try PreviewParser.parse(fileAt: fileURL)

        // Structured payload — always safe to emit, even for empty lists.
        // No session is active here so `activeIndex: -1` sentinel means
        // no `.active == true` entries.
        let structured = DaemonProtocol.PreviewListResult(
            file: fileURL.path,
            previews: previews.map {
                DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: -1)
            }
        )

        if previews.isEmpty {
            return try CallTool.Result(
                content: [.text("No #Preview blocks found in \(fileURL.lastPathComponent)")],
                structuredContent: structured
            )
        }

        var lines: [String] = []
        for preview in previews {
            let name = preview.name ?? "Preview"
            lines.append("[\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)")
        }

        return try CallTool.Result(
            content: [.text(lines.joined(separator: "\n"))],
            structuredContent: structured
        )
    }
}

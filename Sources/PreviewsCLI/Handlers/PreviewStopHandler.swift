import Foundation
import MCP
import PreviewsCore

enum PreviewStopHandler: ToolHandler {
    static let name: ToolName = .previewStop

    static let schema = Tool(
        name: ToolName.previewStop.rawValue,
        description: "Close a preview and clean up the session.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from preview_start"),
                ])
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

        Log.info("preview_stop: enter sessionID=\(sessionID)")

        guard let handle = await ctx.router.handle(for: sessionID) else {
            return CallTool.Result(
                content: [.text("No session found for \(sessionID).")],
                isError: true
            )
        }

        let platform = handle.platform
        Log.info("preview_stop/\(platform.rawValue): stopping session")
        await handle.stop()
        Log.info("preview_stop/\(platform.rawValue): done")

        // Preserve the platform-prefixed message — `IOSCLIWorkflowTests`
        // asserts on the substring "iOS preview session".
        let prefix = platform == .iOS ? "iOS preview session" : "Preview session"
        return CallTool.Result(content: [.text("\(prefix) \(sessionID) closed.")])
    }
}

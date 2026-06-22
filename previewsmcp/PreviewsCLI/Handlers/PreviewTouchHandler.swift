import Foundation
import MCP

enum PreviewTouchHandler: ToolHandler {
    static let name: ToolName = .previewTouch

    static let schema = Tool(
        name: ToolName.previewTouch.rawValue,
        description:
            "Send a touch event to an iOS simulator preview. Coordinates are in device points. For swipe, x/y is the start point.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Session ID from preview_start (iOS simulator only)"),
                ]),
                "x": .object([
                    "type": .string("number"),
                    "description": .string(
                        "X coordinate in points (start point for swipe)"),
                ]),
                "y": .object([
                    "type": .string("number"),
                    "description": .string(
                        "Y coordinate in points (start point for swipe)"),
                ]),
                "action": .object([
                    "type": .string("string"),
                    "description": .string("'tap' (default) or 'swipe'"),
                ]),
                "toX": .object([
                    "type": .string("number"),
                    "description": .string("End X for swipe"),
                ]),
                "toY": .object([
                    "type": .string("number"),
                    "description": .string("End Y for swipe"),
                ]),
                "duration": .object([
                    "type": .string("number"),
                    "description": .string("Swipe duration in seconds (default: 0.3)"),
                ]),
            ]),
            "required": .array([.string("sessionID"), .string("x"), .string("y")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let sessionID: String
        let x: Double
        let y: Double
        do {
            sessionID = try extractString("sessionID", from: params)
            x = try extractDouble("x", from: params)
            y = try extractDouble("y", from: params)
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        guard let iosSession = await ctx.iosState.getSession(sessionID) else {
            return CallTool.Result(
                content: [
                    .text("No iOS session found for \(sessionID). Touch is only supported for iOS simulator previews.")
                ], isError: true)
        }

        let action = extractOptionalString("action", from: params) ?? "tap"

        if action == "swipe" {
            let toX: Double
            let toY: Double
            do {
                toX = try extractDouble("toX", from: params)
                toY = try extractDouble("toY", from: params)
            } catch {
                return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
            }

            let duration = extractOptionalDouble("duration", from: params) ?? 0.3

            try await iosSession.sendSwipe(fromX: x, fromY: y, toX: toX, toY: toY, duration: duration)
            return CallTool.Result(content: [.text("Swipe from (\(Int(x)),\(Int(y))) to (\(Int(toX)),\(Int(toY)))")])
        }

        try await iosSession.sendTap(x: x, y: y)

        // Wait briefly for the touch to register and UI to update
        try await Task.sleep(for: .milliseconds(300))

        return CallTool.Result(content: [.text("Tap sent at (\(Int(x)), \(Int(y)))")])
    }
}

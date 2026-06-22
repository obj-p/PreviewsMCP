import Foundation
import MCP
import PreviewsCore
import PreviewsEngine

enum PreviewSwitchHandler: ToolHandler {
    static let name: ToolName = .previewSwitch

    static let schema = Tool(
        name: ToolName.previewSwitch.rawValue,
        description:
            "Switch which #Preview block is rendered in a running session. Triggers recompile; @State is reset. Traits persist across switches.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from preview_start"),
                ]),
                "previewIndex": .object([
                    "type": .string("integer"),
                    "description": .string(
                        "0-based index of the #Preview block to switch to"),
                ]),
            ]),
            "required": .array([.string("sessionID"), .string("previewIndex")]),
        ])
    )

    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let sessionID: String
        let newIndex: Int
        do {
            sessionID = try extractString("sessionID", from: params)
            newIndex = try extractInt("previewIndex", from: params)
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        guard let handle = await ctx.router.handle(for: sessionID) else {
            return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
        }

        // Bounds-check before delegating. The compile path will also
        // validate (PreviewSession.compile throws previewNotFound) but
        // an early structured error guarantees a fast, deterministic
        // failure regardless of any upstream transport state. See #127.
        let previews = try PreviewParser.parse(fileAt: handle.sourceFile)
        if let outOfRange = previewIndexOutOfRangeError(newIndex, count: previews.count) {
            return outOfRange
        }

        let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 1)
        await progress.report(.compilingBridge, message: "Switching to preview \(newIndex)...")
        try await handle.switchPreview(to: newIndex)

        let activeTraits = await handle.currentTraits
        let traitInfo = activeTraits.isEmpty ? "" : " Traits: \(traitsSummary(activeTraits))."

        let previewList = formatPreviewList(previews: previews, activeIndex: newIndex)
        let structured = DaemonProtocol.SwitchResult(
            sessionID: sessionID,
            activeIndex: newIndex,
            traits: DaemonProtocol.TraitsDTO.orNil(activeTraits),
            previews: previews.map {
                DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: newIndex)
            }
        )
        return try CallTool.Result(
            content: [
                .text(
                    "Switched to preview \(newIndex) in session \(sessionID).\(traitInfo) View recompiled (@State was reset).\n\(previewList)"
                )
            ],
            structuredContent: structured
        )
    }
}

/// Validate `previewIndex` against the parsed preview count. Returns a
/// structured error result if out of range, or `nil` if the index is
/// valid. `SwitchCommandTests.switchOutOfRange` asserts on the exact
/// "out of range" substring.
private func previewIndexOutOfRangeError(_ newIndex: Int, count: Int) -> CallTool.Result? {
    guard newIndex < 0 || newIndex >= count else { return nil }
    return CallTool.Result(
        content: [
            .text("Preview index \(newIndex) out of range (available: 0..<\(count))")
        ],
        isError: true
    )
}

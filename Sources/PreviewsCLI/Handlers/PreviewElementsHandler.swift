import Foundation
import MCP

enum PreviewElementsHandler: ToolHandler {
    static let name: ToolName = .previewElements

    static let schema = Tool(
        name: ToolName.previewElements.rawValue,
        description:
            "Get the accessibility tree of an iOS simulator preview. Returns elements with labels, frames, and traits for targeted interaction.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string(
                        "Session ID from preview_start (iOS simulator only)"),
                ]),
                "filter": .object([
                    "type": .string("string"),
                    "enum": .array([
                        .string("all"), .string("interactable"), .string("labeled"),
                    ]),
                    "description": .string(
                        "Filter mode: 'all' (default) returns the full tree, 'interactable' returns only buttons/links/toggles, 'labeled' returns only elements with label/value/identifier"
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

        guard let iosSession = await ctx.iosState.getSession(sessionID) else {
            return CallTool.Result(
                content: [
                    .text(
                        "No iOS session found for \(sessionID). Elements are only available for iOS simulator previews."
                    )
                ], isError: true)
        }

        let validFilters: Set<String> = ["all", "interactable", "labeled"]
        let filter = extractOptionalString("filter", from: params) ?? "all"
        guard validFilters.contains(filter) else {
            return CallTool.Result(
                content: [.text("Invalid filter '\(filter)'. Must be one of: all, interactable, labeled")],
                isError: true)
        }

        let elementsJSON = try await iosSession.fetchElements(filter: filter)

        // Parse WDA's JSON into a `Value` so the structured payload carries
        // the tree natively rather than as an opaque string. The text block
        // keeps the raw JSON for agents that don't consume
        // `structuredContent`.
        let structured: Value?
        if let data = elementsJSON.data(using: .utf8),
            let tree = try? JSONDecoder().decode(Value.self, from: data)
        {
            structured = .object([
                "sessionID": .string(sessionID),
                "elements": tree,
            ])
        } else {
            structured = nil
        }

        return CallTool.Result(
            content: [.text(elementsJSON)],
            structuredContent: structured
        )
    }
}

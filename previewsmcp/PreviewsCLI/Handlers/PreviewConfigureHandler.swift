import Foundation
import MCP
import PreviewsCore
import PreviewsEngine

enum PreviewConfigureHandler: ToolHandler {
    static let name: ToolName = .previewConfigure

    static let schema = Tool(
        name: ToolName.previewConfigure.rawValue,
        description:
            "Change rendering traits (color scheme, dynamic type, locale, layout direction, legibility weight) for a running preview. Triggers recompile; @State is reset. Pass empty string to clear a trait. Note: dynamicTypeSize only has a visible effect on iOS simulator — macOS does not scale fonts in response to this modifier.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from preview_start"),
                ]),
                "colorScheme": traitProperty(
                    enumValues: PreviewTraits.validColorSchemes,
                    description: "Color scheme override"
                ),
                "dynamicTypeSize": traitProperty(
                    enumValues: PreviewTraits.validDynamicTypeSizes,
                    description: "Dynamic Type size override"
                ),
                "locale": traitProperty(
                    description:
                        "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP'). Pass empty string to clear."
                ),
                "layoutDirection": traitProperty(
                    description:
                        "Layout direction: 'leftToRight' or 'rightToLeft'. Pass empty string to clear."
                ),
                "legibilityWeight": traitProperty(
                    description:
                        "Legibility weight: 'regular' or 'bold'. Pass empty string to clear."
                ),
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

        // Parse and validate traits
        let (traits, clearedFields, validationError) = parseTraits(from: params)
        if let validationError { return validationError }

        // "No-op" = no fields were set AND no fields were requested to be cleared.
        if traits.isEmpty && clearedFields.isEmpty {
            return CallTool.Result(content: [.text("No configuration changes specified.")])
        }

        guard let handle = await ctx.router.handle(for: sessionID) else {
            return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
        }

        let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 1)
        await progress.report(.compilingBridge, message: "Recompiling with new traits...")
        try await handle.reconfigure(traits: traits, clearing: clearedFields)

        let activeTraits = await handle.currentTraits
        return CallTool.Result(content: [
            .text(
                "Configured session \(sessionID): \(traitsSummary(activeTraits)). View recompiled (@State was reset)."
            )
        ])
    }
}

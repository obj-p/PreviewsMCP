import Foundation
import MCP
import PreviewsCore

enum PreviewVariantsHandler: ToolHandler {
    static let name: ToolName = .previewVariants

    static let schema = Tool(
        name: ToolName.previewVariants.rawValue,
        description:
            "Capture screenshots under multiple trait configurations in a single call. Renders each variant, snapshots it, then restores original traits. Accepts preset names or JSON trait objects.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([
                "sessionID": .object([
                    "type": .string("string"),
                    "description": .string("Session ID from preview_start"),
                ]),
                "variants": .object([
                    "type": .string("array"),
                    "items": .object([
                        "type": .string("string"),
                        "description": .string(
                            "Preset name ('light', 'dark', 'xSmall'…'accessibility5', 'rtl', 'ltr', 'boldText') or a JSON object string with any combination of colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight, and an optional label."
                        ),
                    ]),
                    "description": .string(
                        "Array of trait variants to snapshot. Example: [\"light\", \"dark\", \"accessibility3\"]"
                    ),
                ]),
                "quality": .object([
                    "type": .string("number"),
                    "description": .string(
                        "JPEG quality 0.0-1.0 (default: 0.85). Values >= 1.0 produce PNG output."
                    ),
                ]),
            ]),
            "required": .array([.string("sessionID"), .string("variants")]),
        ])
    )

    /// Capture a screenshot under each of N trait configurations.
    ///
    /// **Concurrent-modification caveat:** `PreviewSession` is an actor so
    /// its state transitions are serialized, but a second client calling
    /// `preview_configure` or `preview_switch` against the same session
    /// while variants is mid-loop will interleave its trait changes into
    /// our capture stream — subsequent variant screenshots would reflect
    /// the other client's mutation. The daemon does not hold a per-session
    /// lock across tool calls. Callers that want deterministic variants
    /// should ensure they own the session for the duration.
    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        let sessionID: String
        let variantValues: [Value]
        do {
            sessionID = try extractString("sessionID", from: params)
            variantValues = try extractArray("variants", from: params)
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        guard !variantValues.isEmpty else {
            return CallTool.Result(
                content: [.text(VariantError.emptyVariantsArray.localizedDescription)], isError: true)
        }

        // Resolve all variants upfront — fail fast on validation errors before any recompilation
        let resolved: [PreviewTraits.Variant]
        do {
            resolved = try variantValues.map { try resolveVariant($0) }
        } catch {
            return CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        }

        guard let handle = await ctx.router.handle(for: sessionID) else {
            return CallTool.Result(content: [.text("No session found for \(sessionID)")], isError: true)
        }

        let variantConfigQuality = await configQualityForSession(sessionID, ctx: ctx)
        let quality = max(0.0, min(1.0, extractOptionalDouble("quality", from: params) ?? variantConfigQuality ?? 0.85))
        let mimeType = quality >= 1.0 ? "image/png" : "image/jpeg"
        let progress = mcpReporter(server: ctx.server, params: params, totalSteps: 2 * resolved.count)

        let savedTraits = await handle.currentTraits
        var contentBlocks: [Tool.Content] = []
        var outcomes: [DaemonProtocol.VariantOutcomeDTO] = []
        var failCount = 0

        for (index, variant) in resolved.enumerated() {
            do {
                await progress.report(
                    .compilingBridge, message: "Recompiling for variant \"\(variant.label)\"...")
                try await handle.setTraits(variant.traits)
                await handle.awaitLayoutSettle()
                await progress.report(
                    .capturingSnapshot,
                    message: "Capturing variant \(index + 1)/\(resolved.count) \"\(variant.label)\"...")
                let imageData = try await handle.snapshot(quality: quality)
                let base64 = imageData.base64EncodedString()
                contentBlocks.append(.text("[\(index)] \(variant.label):"))
                contentBlocks.append(.image(data: base64, mimeType: mimeType, metadata: nil))
                // imageIndex addresses the .image block we just appended.
                outcomes.append(
                    DaemonProtocol.VariantOutcomeDTO(
                        status: "ok",
                        index: index,
                        label: variant.label,
                        imageIndex: contentBlocks.count - 1,
                        error: nil
                    )
                )
            } catch {
                failCount += 1
                contentBlocks.append(
                    .text("[\(index)] \(variant.label): ERROR — \(error.localizedDescription)"))
                outcomes.append(
                    DaemonProtocol.VariantOutcomeDTO(
                        status: "error",
                        index: index,
                        label: variant.label,
                        imageIndex: nil,
                        error: error.localizedDescription
                    )
                )
            }
        }

        // Restore original traits if they changed — but only if the
        // session is still registered. A concurrent `preview_stop` during
        // the capture loop will tear down the session; attempting to
        // setTraits on the torn-down session produces a misleading
        // "failed to restore" warning when the user explicitly asked
        // for the stop.
        let stillRegistered = await handle.isRegistered
        let currentTraits = await handle.currentTraits
        if stillRegistered, savedTraits != currentTraits {
            do {
                try await handle.setTraits(savedTraits)
            } catch {
                contentBlocks.append(
                    .text("Warning: failed to restore original traits: \(error.localizedDescription)"))
            }
        }

        let structured = DaemonProtocol.VariantsResult(
            variants: outcomes,
            successCount: outcomes.count - failCount,
            failCount: failCount
        )
        return try CallTool.Result(
            content: contentBlocks,
            structuredContent: structured,
            isError: failCount == resolved.count
        )
    }
}

private enum VariantError: Error, LocalizedError {
    case invalidVariantType
    case emptyVariantsArray

    var errorDescription: String? {
        switch self {
        case .invalidVariantType:
            return
                "Each variant must be a preset name string or a JSON object string with trait fields (colorScheme, dynamicTypeSize, locale, layoutDirection, legibilityWeight)"
        case .emptyVariantsArray:
            return "variants array must not be empty"
        }
    }
}

/// Unwrap an MCP Value to a String, then resolve via PreviewTraits.parseVariantString.
private func resolveVariant(_ value: Value) throws -> PreviewTraits.Variant {
    guard case .string(let str) = value else {
        throw VariantError.invalidVariantType
    }
    return try PreviewTraits.parseVariantString(str)
}

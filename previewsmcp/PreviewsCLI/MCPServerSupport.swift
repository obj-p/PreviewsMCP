import Foundation
import MCP
import os
import PreviewsCore
import PreviewsEngine
import PreviewsIOS

// MARK: - Progress

/// MCP progress reporter that sends progress notifications and log messages to the client.
final class MCPProgressReporter: ProgressReporter, @unchecked Sendable {
    private let server: any MCPServing
    private let progressToken: ProgressToken?
    private let totalSteps: Int
    private let stepCounter: OSAllocatedUnfairLock<Int>

    init(server: any MCPServing, progressToken: ProgressToken?, totalSteps: Int) {
        self.server = server
        self.progressToken = progressToken
        self.totalSteps = totalSteps
        stepCounter = OSAllocatedUnfairLock(initialState: 0)
    }

    func report(_: BuildPhase, message: String) async {
        let step = stepCounter.withLock { value -> Int in
            value += 1
            return value
        }
        try? await server.log(
            level: .info, logger: "preview",
            data: .string("[\(step)/\(totalSteps)] \(message)")
        )
        if let token = progressToken {
            try? await server.notify(
                ProgressNotification.message(
                    .init(
                        progressToken: token,
                        progress: Double(step),
                        total: Double(totalSteps),
                        message: message
                    )
                )
            )
        }
    }
}

/// Create an MCP progress reporter for the given tool call parameters.
func mcpReporter(
    server: any MCPServing, params: CallTool.Parameters, totalSteps: Int
) -> MCPProgressReporter {
    MCPProgressReporter(
        server: server,
        progressToken: params._meta?.progressToken,
        totalSteps: totalSteps
    )
}

// MARK: - Server lifecycle

/// The version string the daemon advertises in MCP `serverInfo.version`.
/// Normally `PreviewsMCPCommand.version` (the compile-time value), but
/// integration tests override it via `_PREVIEWSMCP_TEST_DAEMON_VERSION`
/// to exercise the client-side version-mismatch restart path without
/// needing two separately-versioned binaries. See issue #142. Leading
/// underscore signals "internal, not a supported user knob." The client
/// never reads this variable.
func advertisedServerVersion() -> String {
    if let override = ProcessInfo.processInfo.environment["_PREVIEWSMCP_TEST_DAEMON_VERSION"],
       !override.isEmpty
    {
        return override
    }
    return PreviewsMCPCommand.version
}

/// Run the MCP server's event loop on `transport`. Returns when the
/// transport closes (client disconnected or server shutdown).
///
/// Liveness is protocol-layer MCP ping in BOTH directions (stage 6),
/// replacing the retired 2s `logger: "heartbeat"` log-notification hack:
/// the server pings its client per `configureMCPServer`'s `liveness`
/// parameter, and the in-house client pings the daemon on its own
/// cadence to bound wedged-daemon detection (issue #135's silence
/// problem — swiftc recompiles and simulator boots are legitimately
/// quiet). Timing contract for clients: an idle connection carries NO
/// unsolicited server traffic, so a client-side liveness window must be
/// fed by its own ping round-trips, never by passive listening.
func runMCPServer(_ server: any MCPServing, transport: any Transport) async throws {
    try await server.start(transport: transport)
    // `server.start` returns once its internal receive Task is spawned,
    // NOT when the transport closes. Wait explicitly.
    await server.waitUntilCompleted()
}

// MARK: - Trait parsing (shared by preview_start and preview_configure)

/// Parse and validate trait parameters. Returns (traits, clearedFields, nil) on
/// success or (default traits, [], error result) on failure. Callers should
/// check the last element first; the other values are meaningless on error.
///
/// `clearedFields` names the fields the client explicitly passed as an empty
/// string (the "clear this trait" signal documented in the MCP tool schema).
/// Without this, empty strings would be indistinguishable from absent fields
/// after `PreviewTraits.validated` normalizes them to nil.
func parseTraits(
    from params: CallTool.Parameters
) -> (PreviewTraits, Set<PreviewTraits.Field>, CallTool.Result?) {
    let cleared = clearedTraitFields(in: params)
    do {
        let traits = try PreviewTraits.validated(
            colorScheme: extractOptionalString("colorScheme", from: params),
            dynamicTypeSize: extractOptionalString("dynamicTypeSize", from: params),
            locale: extractOptionalString("locale", from: params),
            layoutDirection: extractOptionalString("layoutDirection", from: params),
            legibilityWeight: extractOptionalString("legibilityWeight", from: params)
        )
        return (traits, cleared, nil)
    } catch {
        return (
            PreviewTraits(), [],
            CallTool.Result(content: [.text(error.localizedDescription)], isError: true)
        )
    }
}

/// Returns the set of trait fields that the client passed as an empty string
/// ("" — the documented clear signal). Does not touch fields that were absent
/// from the params entirely.
func clearedTraitFields(
    in params: CallTool.Parameters
) -> Set<PreviewTraits.Field> {
    var cleared: Set<PreviewTraits.Field> = []
    for field in PreviewTraits.Field.allCases {
        if case .string("") = params.arguments?[field.rawValue] {
            cleared.insert(field)
        }
    }
    return cleared
}

// MARK: - Session-config helpers

/// Resolve the config quality default for a session (iOS or macOS).
/// Used by `preview_snapshot` and `preview_variants`.
func configQualityForSession(_ sessionID: String, ctx: HandlerContext) async -> Double? {
    guard let handle = await ctx.router.handle(for: sessionID) else { return nil }
    return loadProjectConfig(explicit: nil, fileURL: handle.sourceFile)?.config.quality
}

/// Classified error for a session whose agent is terminally gone, or nil
/// while healthy. Session-scoped handlers return this instead of
/// operating on a dead session (docs/state-invalidation.md, L04).
func terminalFailureResult(for handle: any PreviewSessionHandle) async -> CallTool.Result? {
    guard let failure = await handle.terminalFailure else { return nil }
    return CallTool.Result(content: [.text(failure)], isError: true)
}

/// Append the session's undisclosed crash notice (if any) as a TRAILING
/// content item. Called as the last step of assembling a success
/// response; never touches `content[0]`, which clients parse as the
/// primary payload.
func appendingIncidentNotice(
    _ result: CallTool.Result, from handle: any PreviewSessionHandle
) async -> CallTool.Result {
    guard let notice = await handle.takeIncidentNotice() else { return result }
    return appending(notice, to: result)
}

/// `appendingIncidentNotice` for handlers that hold the iOS session
/// directly (touch, elements) rather than a routed handle.
func appendingCrashNotice(
    _ result: CallTool.Result, from session: IOSPreviewSession
) async -> CallTool.Result {
    guard let notice = await session.takeUndisclosedCrashNotice() else { return result }
    return appending(notice, to: result)
}

private func appending(_ notice: String, to result: CallTool.Result) -> CallTool.Result {
    CallTool.Result(
        content: result.content + [.text(notice)],
        structuredContent: result.structuredContent,
        isError: result.isError
    )
}

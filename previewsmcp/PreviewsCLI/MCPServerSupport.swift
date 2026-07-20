import Foundation
import MCP
import os
import PreviewsCore
import PreviewsEngine

// MARK: - Progress

/// MCP progress reporter that sends progress notifications and log messages to the client.
final class MCPProgressReporter: ProgressReporter, @unchecked Sendable {
    private struct Position {
        var step = 0
        var ticks = 0
    }

    private let server: any MCPServing
    private let progressToken: ProgressToken?
    private let totalSteps: Int
    private let position: OSAllocatedUnfairLock<Position>

    init(server: any MCPServing, progressToken: ProgressToken?, totalSteps: Int) {
        self.server = server
        self.progressToken = progressToken
        self.totalSteps = totalSteps
        position = OSAllocatedUnfairLock(initialState: Position())
    }

    func report(_: BuildPhase, message: String) async {
        let step = position.withLock { state -> Int in
            state.step += 1
            state.ticks = 0
            return state.step
        }
        await emit(step: step, progress: Double(step), message: message)
    }

    /// Read-only re-emit: holds the step and advances only a fractional
    /// progress bump (capped below the next step, so token clients see
    /// monotonically increasing values) plus the elapsed marker. On the
    /// final step the bump clamps to `totalSteps` — progress must never
    /// exceed the reported total.
    func tick(message: String, elapsed: Duration) async {
        let (step, fraction) = position.withLock { state -> (Int, Double) in
            state.ticks += 1
            return (state.step, min(0.9, 0.1 * Double(state.ticks)))
        }
        await emit(
            step: step,
            progress: min(Double(step) + fraction, Double(totalSteps)),
            message: "\(message) (\(elapsed.components.seconds)s)"
        )
    }

    private func emit(step: Int, progress: Double, message: String) async {
        try? await server.log(
            level: .info, logger: "preview",
            data: .string("[\(step)/\(totalSteps)] \(message)")
        )
        if let token = progressToken {
            try? await server.notify(
                ProgressNotification.message(
                    .init(
                        progressToken: token,
                        progress: progress,
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

// MARK: - Phase failures and notices (docs/phase-error-protocol.md)

/// The ONE place a `PhaseFailure` becomes a tool result: `content[0]` is
/// "<phase> failed: <message>" plus the bounded detail and remediation,
/// and `structuredContent.error` carries the machine-readable
/// classification.
func phaseFailureResult(_ failure: PhaseFailure) -> CallTool.Result {
    var text = "\(failure.phase.userLabel) failed: \(failure.message)"
    if let detail = failure.detail, !detail.isEmpty {
        text += "\n\(detail)"
    }
    if let remediation = failure.remediation {
        text += "\nRemediation: \(remediation)"
    }
    var error: [String: Value] = [
        "phase": .string(failure.phase.rawValue),
        "code": .string(failure.code.rawValue),
        "message": .string(failure.message),
    ]
    if let detail = failure.detail { error["detail"] = .string(detail) }
    if let remediation = failure.remediation { error["remediation"] = .string(remediation) }
    return CallTool.Result(
        content: [.text(text)],
        structuredContent: .object(["error": .object(error)]),
        isError: true
    )
}

/// Boundary adapter: map a thrown domain error to a `PhaseFailure` at the
/// phase the catch site was running. `message` derives from the error's
/// own description so pinned guard tokens survive by construction; an
/// error that is already a `PhaseFailure` passes through untouched.
func classifiedFailure(_ error: Error, at phase: BuildPhase) -> PhaseFailure {
    if let failure = error as? PhaseFailure { return failure }
    return PhaseFailure(
        phase: phase, code: .buildFailed, message: error.localizedDescription
    )
}

/// Classified error for a session whose agent is terminally gone, or nil
/// while healthy. Session-scoped handlers return this instead of
/// operating on a dead session (docs/state-invalidation.md, L04).
func terminalFailureResult(for handle: any PreviewSessionHandle) async -> CallTool.Result? {
    guard let failure = await handle.terminalFailure else { return nil }
    return phaseFailureResult(failure)
}

/// Append notices as TRAILING content items and mirror them into
/// `structuredContent.notices`. The single attach point: called as the
/// last step of assembling a success response; never touches
/// `content[0]`, which clients parse as the primary payload. The mirror
/// is created even when the result had no structure, so CLI consumers
/// can always identify notice items to route to stderr. A non-object
/// structure keeps its shape and skips the mirror — a handler that
/// carries notices must use an object structure (all current ones do).
func appendingNotices(
    _ result: CallTool.Result, _ notices: [Notice]
) -> CallTool.Result {
    guard !notices.isEmpty else { return result }
    let mirror = Value.array(notices.map {
        .object(["code": .string($0.code.rawValue), "message": .string($0.message)])
    })
    let structured: Value? = switch result.structuredContent {
    case let .object(fields):
        .object(fields.merging(["notices": mirror]) { _, new in new })
    case nil:
        .object(["notices": mirror])
    case let .some(other):
        other
    }
    return CallTool.Result(
        content: result.content + notices.map { .text($0.message) },
        structuredContent: structured,
        isError: result.isError
    )
}

/// Append the session's undisclosed crash notice (if any) through the
/// notices carrier.
func appendingIncidentNotice(
    _ result: CallTool.Result, from handle: any PreviewSessionHandle
) async -> CallTool.Result {
    guard let notice = await handle.takeIncidentNotice() else { return result }
    return appendingNotices(result, [notice])
}

import Foundation
import MCP
import PreviewsCore
import PreviewsEngine
import os

// MARK: - Progress

/// MCP progress reporter that sends progress notifications and log messages to the client.
final class MCPProgressReporter: ProgressReporter, @unchecked Sendable {
    private let server: Server
    private let progressToken: ProgressToken?
    private let totalSteps: Int
    private let stepCounter: OSAllocatedUnfairLock<Int>

    init(server: Server, progressToken: ProgressToken?, totalSteps: Int) {
        self.server = server
        self.progressToken = progressToken
        self.totalSteps = totalSteps
        self.stepCounter = OSAllocatedUnfairLock(initialState: 0)
    }

    func report(_ phase: BuildPhase, message: String) async {
        let step = stepCounter.withLock { value -> Int in
            value += 1
            return value
        }
        try? await server.log(
            level: .info, logger: "preview",
            data: .string("[\(step)/\(totalSteps)] \(message)"))
        if let token = progressToken {
            try? await server.notify(
                ProgressNotification.message(
                    .init(
                        progressToken: token,
                        progress: Double(step),
                        total: Double(totalSteps),
                        message: message
                    )))
        }
    }
}

/// Create an MCP progress reporter for the given tool call parameters.
func mcpReporter(
    server: Server, params: CallTool.Parameters, totalSteps: Int
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

/// Run the MCP server's event loop on `transport`, emitting a periodic
/// heartbeat log notification that clients can use as a liveness signal.
/// Returns when the transport closes (client disconnected or server
/// shutdown). The heartbeat Task is cancelled on return.
///
/// Why the heartbeat: daemon handlers can be legitimately silent for
/// long stretches (swiftc recompiles, simulator boot), and stall-
/// detection layers downstream have no way to distinguish that from a
/// genuinely wedged daemon. A 2s unconditional ping fires regardless of
/// whether any tool call is in flight, covering both the
/// request-scoped silence and the between-request silence (e.g., the
/// FileWatcher reload path — see issue #135).
///
/// Why `LogMessageNotification` with `logger: "heartbeat"` rather than
/// `ProgressNotification`: per the MCP spec, progress notifications
/// require a `progressToken` from an in-flight request. An unsolicited
/// heartbeat has no such token. `LogMessageNotification`'s optional
/// `logger` discriminator lets clients filter these out of human-visible
/// log surfaces (see `DaemonClient.registerStderrLogForwarder`) while
/// still receiving them as liveness-timer bumps.
///
/// Timing contract for downstream consumers (Phase 2 stall detector): the
/// first ping fires at T+2s relative to `server.start`, not T+0. A
/// client-side liveness timer should grant at least one full heartbeat
/// interval of grace on connect before declaring the daemon wedged.
func runMCPServer(_ server: Server, transport: any Transport) async throws {
    let heartbeat = Task.detached {
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            try? await server.log(
                level: .debug, logger: "heartbeat", data: .string("alive"))
        }
    }
    defer { heartbeat.cancel() }
    try await server.start(transport: transport)
    // `server.start` returns once its internal receive Task is spawned,
    // NOT when the transport closes. Wait explicitly so the heartbeat's
    // defer-cancel fires only after the server is actually done serving.
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
    return await ctx.configCache.load(for: handle.sourceFile)?.config.quality
}

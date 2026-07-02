import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// Test double for `DaemonToolCalling`. Scripted with canned
/// `CallTool.Result`s per tool name — no socket, no spawned daemon. Records
/// every call so tests can assert on what a command actually sent.
///
/// Two ways to script a tool name: `responses` for a single repeatable
/// result (the common case), and `sequences` for a command that calls the
/// same tool name more than once per `execute` and needs a distinct result
/// per call (e.g. `StopCommand.stopAll`'s per-session `preview_stop` loop —
/// one session fails, the rest still get stopped). A tool name present in
/// `sequences` is popped FIFO on each call; once exhausted, falls back to
/// `responses`.
final class FakeDaemonClient: DaemonToolCalling, @unchecked Sendable {
    private let responses: [String: CallTool.Result]
    private var sequences: [String: [CallTool.Result]]
    private(set) var calls: [(name: String, arguments: [String: Value]?)] = []

    init(
        responses: [String: CallTool.Result] = [:],
        sequences: [String: [CallTool.Result]] = [:]
    ) {
        self.responses = responses
        self.sequences = sequences
    }

    func callToolStructured(
        name: String,
        arguments: [String: Value]?
    ) async throws -> CallTool.Result {
        calls.append((name, arguments))
        if var queue = sequences[name], !queue.isEmpty {
            let result = queue.removeFirst()
            sequences[name] = queue
            return result
        }
        guard let result = responses[name] else {
            throw FakeDaemonClientError.noCannedResponse(name)
        }
        return result
    }
}

enum FakeDaemonClientError: Error, CustomStringConvertible {
    case noCannedResponse(String)

    var description: String {
        switch self {
        case let .noCannedResponse(name):
            "FakeDaemonClient has no canned response for tool \"\(name)\""
        }
    }
}

extension CallTool.Result {
    /// An empty `session_list` response — no active sessions.
    static let noSessions = CallTool.Result(content: [.text("")])

    /// A `session_list` response with exactly one active session (id
    /// "test-session"), matching `SessionResolver.parseSessionList`'s
    /// tab-delimited format (`<sessionID>\t<platform>\t<sourceFilePath>`).
    static let foundSession = CallTool.Result(
        content: [.text("test-session\tmacos\t/tmp/previewsmcp-logic-test.swift")]
    )

    /// A `session_list` response with two active sessions ("session-a",
    /// "session-b"), for commands that sweep every session (e.g.
    /// `StopCommand.stopAll`).
    static let twoSessions = CallTool.Result(
        content: [.text("session-a\tmacos\t/tmp/a.swift\nsession-b\tios\t/tmp/b.swift")]
    )

    /// A daemon-reported tool error — `isError == true` with a message.
    static func daemonError(_ message: String) -> CallTool.Result {
        CallTool.Result(content: [.text(message)], isError: true)
    }

    /// A successful `preview_start` response for an ephemeral session,
    /// decodable via `structuredContent.decode(DaemonProtocol.PreviewStartResult.self)`
    /// the same way production code does. Used by cleanup-on-throw tests for
    /// the ephemeral-session commands (`SnapshotCommand.snapshotEphemeral`,
    /// `VariantsCommand.captureEphemeral`).
    static func ephemeralStartResult(sessionID: String = "test-session") throws -> CallTool.Result {
        try CallTool.Result(
            structuredContent: DaemonProtocol.PreviewStartResult(
                sessionID: sessionID, platform: "macos",
                sourceFilePath: "/nonexistent/previewsmcp-logic-test/File.swift",
                deviceUDID: nil, pid: nil, traits: nil, previews: [],
                activeIndex: 0, setupWarning: nil, appServerPort: nil
            )
        )
    }
}

/// Runs `run`, expecting it to throw a `DaemonToolError` whose description
/// contains `substring`.
func expectDaemonToolError(
    contains substring: String,
    run: () async throws -> Void
) async {
    do {
        try await run()
        Issue.record("expected a DaemonToolError, but run() succeeded")
    } catch let error as DaemonToolError {
        #expect(error.description.contains(substring), "unexpected message: \(error.description)")
    } catch {
        Issue.record("expected a DaemonToolError, got \(error)")
    }
}

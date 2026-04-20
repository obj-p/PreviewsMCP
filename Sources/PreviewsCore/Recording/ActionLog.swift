import Foundation

/// A single entry in the recording action timeline.
///
/// Captures a tool call that occurred during an active recording session,
/// with its timestamp relative to recording start and a flag indicating
/// whether the call caused a recompile (visible as a cut in the video).
public struct ActionLogEntry: Sendable, Codable, Equatable {
    /// Milliseconds from recording start (monotonic clock).
    public let tMs: Int
    /// MCP tool name that was called.
    public let tool: String
    /// String-typed parameters for the tool call.
    public let params: [String: String]
    /// Whether this tool call caused a preview recompile.
    public let causedRecompile: Bool

    public init(tMs: Int, tool: String, params: [String: String], causedRecompile: Bool) {
        self.tMs = tMs
        self.tool = tool
        self.params = params
        self.causedRecompile = causedRecompile
    }
}

/// Thread-safe action log for recording sessions.
///
/// Accumulates tool calls that occur while a recording session is active.
/// Entries are appended from the dispatcher middleware and retrieved on stop.
public actor ActionLog {

    private var log: [ActionLogEntry] = []

    public init() {}

    /// Append a new entry to the log.
    public func append(
        tMs: Int, tool: String, params: [String: String], causedRecompile: Bool
    ) {
        log.append(
            ActionLogEntry(
                tMs: tMs, tool: tool, params: params, causedRecompile: causedRecompile
            ))
    }

    /// Return all entries in insertion order.
    public func entries() -> [ActionLogEntry] {
        log
    }
}

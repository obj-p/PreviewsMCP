import MCP
import PreviewsEngine

enum SessionListHandler: ToolHandler {
    static let name: ToolName = .sessionList

    static let schema = Tool(
        name: ToolName.sessionList.rawValue,
        description:
            "List all active preview sessions in the daemon, with their source file paths and platforms. Used by CLI commands to resolve --file to --session, and for diagnostic tooling.",
        inputSchema: .object([
            "type": .string("object"),
            "properties": .object([:]),
        ])
    )

    /// List all active sessions (iOS + macOS) across every running
    /// PreviewsMCP process. Output is one line per session in the
    /// format `<sessionID>\t<platform>\t<sourceFilePath>` — tab-delimited
    /// for simple client-side parsing. Empty result when no sessions
    /// are active anywhere.
    ///
    /// The local in-memory state covers sessions THIS process owns;
    /// `SessionRegistry.readOthers()` covers sessions owned by peer
    /// processes (typically: stdio MCP server vs UDS daemon — each
    /// holds its own session pool, but `session_list` from either
    /// returns the union). See `SessionRegistry` and the architectural
    /// plan's #6b for context.
    static func handle(
        _ params: CallTool.Parameters,
        ctx: HandlerContext
    ) async throws -> CallTool.Result {
        var sessions: [DaemonProtocol.SessionDTO] = []

        let iosSessions = await ctx.iosState.allSessionsInfo()
        for session in iosSessions {
            sessions.append(
                DaemonProtocol.SessionDTO(
                    sessionID: session.id,
                    platform: "ios",
                    sourceFilePath: session.sourceFile.path
                )
            )
        }

        let host = ctx.host
        let macSessions = await MainActor.run { host.allSessions }
        for (id, session) in macSessions {
            sessions.append(
                DaemonProtocol.SessionDTO(
                    sessionID: id,
                    platform: "macos",
                    sourceFilePath: session.sourceFile.path
                )
            )
        }

        // Merge in sessions published by peer processes via the
        // cross-process registry. Stale-PID filtering and lazy
        // file cleanup happen inside `readOthers()`.
        let peerEntries = await ctx.registry.readOthers()
        for entry in peerEntries {
            sessions.append(
                DaemonProtocol.SessionDTO(
                    sessionID: entry.sessionID,
                    platform: entry.platform,
                    sourceFilePath: entry.sourceFilePath
                )
            )
        }

        // Stable ordering so clients parsing the output get consistent results.
        sessions.sort { $0.sessionID < $1.sessionID }
        let lines = sessions.map { "\($0.sessionID)\t\($0.platform)\t\($0.sourceFilePath)" }

        // An empty lines array joins to "" — matches the legacy "no active
        // sessions" response that SessionResolver.parseSessionList handles.
        let textBlock: [Tool.Content] = [.text(lines.joined(separator: "\n"))]

        // Use do/try and fall back to the text-only response if Codable
        // encoding somehow throws; handleSessionList is non-throwing in
        // practice — encoding [SessionDTO] is trivial and won't fail.
        do {
            return try CallTool.Result(
                content: textBlock,
                structuredContent: DaemonProtocol.SessionListResult(sessions: sessions)
            )
        } catch {
            return CallTool.Result(content: textBlock)
        }
    }
}

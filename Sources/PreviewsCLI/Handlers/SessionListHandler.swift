import MCP

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

    /// List all active sessions (iOS + macOS). Output is one line per session in
    /// the format `<sessionID>\t<platform>\t<sourceFilePath>` — tab-delimited for
    /// simple client-side parsing. Empty result when no sessions are active.
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

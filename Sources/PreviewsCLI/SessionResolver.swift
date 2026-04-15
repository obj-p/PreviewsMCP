import Foundation
import MCP

/// Resolves CLI session-targeting flags (`--session <uuid>` / `--file <path>`
/// / no flag) to an active session in the daemon.
///
/// Centralizes the "smart default" policy from the spec: when exactly one
/// session is running, commands can omit the flags entirely and we use that
/// sole session. When zero or multiple sessions are running and no flag
/// disambiguates, return a clear error.
enum SessionResolver {

    /// Resolve a session targeting policy. Returns `.found(id)` on success
    /// or `.notFound` when the caller should decide how to proceed
    /// (e.g., snapshot creates an ephemeral session; configure errors out).
    static func resolve(
        session: String?,
        file: String?,
        client: Client
    ) async throws -> Resolution {
        // Explicit --session wins over everything else. We don't verify
        // existence here — the subsequent MCP call will fail with a useful
        // error if the session is gone.
        if let session {
            return .found(sessionID: session)
        }
        let activeSessions = try await listSessions(client: client)
        return try resolveAgainst(
            sessions: activeSessions, file: file
        )
    }

    /// Pure resolution policy, extracted so it can be tested without an MCP
    /// client. Given a snapshot of active sessions and an optional file
    /// filter, apply the same "smart default" rules as `resolve(session:file:client:)`:
    /// - `file` matches exactly one session → that session
    /// - `file` matches none → `.notFound`
    /// - `file` matches multiple → `.multipleMatches` error
    /// - no `file`, one session → that session
    /// - no `file`, no sessions → `.notFound`
    /// - no `file`, multiple sessions → `.ambiguous` error
    static func resolveAgainst(
        sessions activeSessions: [SessionInfo],
        file: String?
    ) throws -> Resolution {
        if let file {
            let targetPath = URL(fileURLWithPath: file).standardizedFileURL.path
            let matches = activeSessions.filter { $0.sourceFilePath == targetPath }
            switch matches.count {
            case 0:
                return .notFound
            case 1:
                return .found(sessionID: matches[0].sessionID)
            default:
                throw SessionResolverError.multipleMatches(
                    file: targetPath,
                    sessionIDs: matches.map(\.sessionID)
                )
            }
        }

        switch activeSessions.count {
        case 0:
            return .notFound
        case 1:
            return .found(sessionID: activeSessions[0].sessionID)
        default:
            throw SessionResolverError.ambiguous(sessions: activeSessions)
        }
    }

    /// Query the daemon for the list of active sessions.
    private static func listSessions(client: Client) async throws -> [SessionInfo] {
        let response = try await client.callTool(name: "session_list", arguments: [:])
        if response.isError == true {
            throw SessionResolverError.daemonError(
                response.content.joinedText()
            )
        }
        let text = response.content.joinedText()
        return parseSessionList(text)
    }

    /// Parse the tab-delimited output of `session_list` into structured
    /// session info. Each line: `<sessionID>\t<platform>\t<sourceFilePath>`.
    static func parseSessionList(_ text: String) -> [SessionInfo] {
        text.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line in
            let parts = line.split(separator: "\t", omittingEmptySubsequences: false)
            guard parts.count == 3 else { return nil }
            return SessionInfo(
                sessionID: String(parts[0]),
                platform: String(parts[1]),
                sourceFilePath: String(parts[2])
            )
        }
    }

}

extension SessionResolver {

    enum Resolution: Equatable {
        case found(sessionID: String)
        case notFound
    }

    struct SessionInfo: Equatable, Sendable {
        let sessionID: String
        let platform: String
        let sourceFilePath: String
    }
}

enum SessionResolverError: Error, CustomStringConvertible {
    case multipleMatches(file: String, sessionIDs: [String])
    case ambiguous(sessions: [SessionResolver.SessionInfo])
    case daemonError(String)

    var description: String {
        switch self {
        case .multipleMatches(let file, let ids):
            return
                "multiple sessions match \(file): \(ids.joined(separator: ", ")). "
                + "Pass --session <id> to disambiguate."
        case .ambiguous(let sessions):
            let listing =
                sessions
                .map { "  \($0.sessionID) (\($0.platform)) \($0.sourceFilePath)" }
                .joined(separator: "\n")
            return
                "multiple sessions are running; specify one with --session <id> or --file <path>:\n"
                + listing
        case .daemonError(let text):
            return "daemon error: \(text)"
        }
    }
}

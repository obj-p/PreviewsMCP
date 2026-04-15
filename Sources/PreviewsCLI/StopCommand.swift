import ArgumentParser
import Foundation
import MCP

/// Stop one or more running preview sessions.
///
/// Forwards to the daemon's `preview_stop` MCP tool. Targeting mirrors
/// the other session-scoped commands: `--session <uuid>` > `--file
/// <path>` > the sole running session. Pass `--all` to stop every active
/// session in a single invocation.
///
/// This does not kill the daemon itself — use `kill-daemon` for that.
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop a running preview session",
        discussion: """
            Closes a preview session and releases its resources. Targets
            the session using the same resolution rules as configure and
            switch: pass --session for a specific session, --file to
            look up by source path, or no flag when exactly one session
            is running.

            Use --all to stop every active session (for example, before
            shutting down the daemon cleanly). --all cannot be combined
            with --session or --file.
            """
    )

    @OptionGroup var target: SessionTargetingOptions

    @Flag(name: .long, help: "Stop every active session in the daemon")
    var all: Bool = false

    mutating func run() async throws {
        if all, target.session != nil || target.file != nil {
            throw ValidationError("--all cannot be combined with --session or --file.")
        }

        try await DaemonClient.withDaemonClient(name: "previewsmcp-stop") { client in
            if all {
                try await stopAll(client: client)
            } else {
                try await stopOne(client: client)
            }
        }
    }

    private func stopOne(client: Client) async throws {
        let resolution = try await SessionResolver.resolve(
            session: target.session,
            file: target.file,
            client: client
        )

        guard case .found(let sessionID) = resolution else {
            throw ValidationError(
                "No session found to stop. Start one with "
                    + "`previewsmcp run <file> --detach` or pass an "
                    + "explicit --session <uuid>."
            )
        }

        try await sendStop(sessionID: sessionID, client: client)
    }

    private func stopAll(client: Client) async throws {
        let response = try await client.callTool(name: "session_list", arguments: [:])
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
        let sessions = SessionResolver.parseSessionList(response.content.joinedText())

        if sessions.isEmpty {
            fputs("No active sessions to stop.\n", stderr)
            return
        }

        // Sequential rather than parallel: the daemon serializes tool
        // calls on a single actor anyway, and sequential execution keeps
        // the per-session log output interleaved predictably.
        var firstFailure: Error?
        for info in sessions {
            do {
                try await sendStop(sessionID: info.sessionID, client: client)
            } catch {
                // Keep going — one bad session shouldn't prevent us from
                // cleaning up the others. Stash the first failure and
                // throw it once the sweep is done; ArgumentParser's
                // error path will surface it exactly once.
                if firstFailure == nil { firstFailure = error }
            }
        }

        if let firstFailure { throw firstFailure }
    }

    private func sendStop(sessionID: String, client: Client) async throws {
        let response = try await client.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
        if response.isError == true {
            throw DaemonToolError.daemonError(response.content.joinedText())
        }
        let text = response.content.joinedText()
        if !text.isEmpty { fputs("\(text)\n", stderr) }
    }
}


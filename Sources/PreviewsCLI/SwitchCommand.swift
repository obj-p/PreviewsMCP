import ArgumentParser
import Foundation
import MCP

/// Switch which `#Preview` block is rendered in a running session.
///
/// Forwards to the daemon's `preview_switch` MCP tool. The daemon
/// recompiles the affected session (which resets `@State`); traits persist
/// across the switch.
///
/// Session targeting mirrors `configure` and `snapshot`: `--session <id>` >
/// `--file <path>` > the sole running session. As with `configure`, there
/// is no ephemeral fallback — switching a session that doesn't exist is an
/// error.
struct SwitchCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "switch",
        abstract: "Switch which #Preview block is active in a running session",
        discussion: """
            Selects a different #Preview block to render. Use
            `previewsmcp list <file>` to enumerate available previews.

            Targets the session using the same resolution rules as
            `configure` and `snapshot`: pass --session for a specific
            session, --file to look up by source path, or no flag when
            exactly one session is running.

            @State is reset on each switch; traits (color scheme, dynamic
            type, locale, etc.) persist.
            """
    )

    @Argument(help: "0-based index of the #Preview block to render")
    var previewIndex: Int

    @OptionGroup var target: SessionTargetingOptions

    mutating func run() async throws {
        guard previewIndex >= 0 else {
            throw ValidationError("Preview index must be non-negative.")
        }

        try await DaemonClient.withDaemonClient(name: "previewsmcp-switch") { client in
            let resolution = try await SessionResolver.resolve(
                session: target.session,
                file: target.file,
                client: client
            )

            guard case .found(let sessionID) = resolution else {
                throw ValidationError(
                    "No session found to switch. Start one with "
                        + "`previewsmcp run <file> --detach` or pass an "
                        + "explicit --session <uuid>."
                )
            }

            let response = try await client.callTool(
                name: "preview_switch",
                arguments: [
                    "sessionID": .string(sessionID),
                    "previewIndex": .int(previewIndex),
                ]
            )
            if response.isError == true {
                throw DaemonToolError.daemonError(response.content.joinedText())
            }

            let text = response.content.joinedText()
            if !text.isEmpty { fputs("\(text)\n", stderr) }
        }
    }

}

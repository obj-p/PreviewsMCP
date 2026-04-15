import ArgumentParser
import Foundation
import MCP

/// Dump the accessibility tree of a running iOS simulator preview.
///
/// Forwards to the daemon's `preview_elements` MCP tool. Writes the tree
/// as JSON to stdout — convenient for piping into `jq` or consuming from
/// a script. The tree contains each element's label, frame, and traits
/// so callers can target taps/swipes by matching against it.
///
/// iOS simulator only. Resolves the session with the same rules as
/// `configure` / `switch`.
struct ElementsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "elements",
        abstract: "Dump the accessibility tree of an iOS simulator preview as JSON",
        discussion: """
            Writes a JSON document to stdout describing the current
            accessibility tree of a running iOS preview. Each element has
            its label, frame, and traits, so you can target taps or swipes
            by matching against the structure.

            Only available for iOS simulator sessions — this command
            errors against a macOS session. Use `--filter interactable`
            or `--filter labeled` to narrow the tree.
            """
    )

    @OptionGroup var target: SessionTargetingOptions

    @Option(
        name: .long,
        help: "Filter mode: 'all' (default), 'interactable', or 'labeled'"
    )
    var filter: Filter = .all

    enum Filter: String, ExpressibleByArgument, CaseIterable {
        case all
        case interactable
        case labeled
    }

    mutating func run() async throws {
        try await DaemonClient.withDaemonClient(name: "previewsmcp-elements") { client in
            let resolution = try await SessionResolver.resolve(
                session: target.session,
                file: target.file,
                client: client
            )

            guard case .found(let sessionID) = resolution else {
                throw ValidationError(
                    "No session found. Start an iOS session with "
                        + "`previewsmcp run <file> --platform ios --detach` or "
                        + "pass an explicit --session <uuid>."
                )
            }

            let response = try await client.callTool(
                name: "preview_elements",
                arguments: [
                    "sessionID": .string(sessionID),
                    "filter": .string(filter.rawValue),
                ]
            )
            if response.isError == true {
                throw DaemonToolError.daemonError(response.content.joinedText())
            }

            // The daemon returns the tree as a single text blob (JSON).
            // Print to stdout so the caller can pipe into `jq`. Skip the
            // trailing newline when the payload is empty so downstream
            // parsers don't see a stray `\n`.
            let text = response.content.joinedText()
            if !text.isEmpty { print(text) }
        }
    }
}


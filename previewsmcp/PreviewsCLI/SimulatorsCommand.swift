import ArgumentParser
import Foundation
import MCP

/// List available iOS simulator devices with their UDIDs and runtimes.
///
/// Forwards to the daemon's `simulator_list` MCP tool. Output is one
/// line per available device:
///
///     iPhone 15 Pro — <udid> [BOOTED] (iOS 17.5)
///
/// Useful for resolving a device UDID to pass as `--device` to a run /
/// snapshot invocation, or for quickly confirming which simulator is
/// currently booted.
struct SimulatorsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "simulators",
        abstract: "List available iOS simulator devices",
        discussion: """
            Writes one line per available device to stdout in the form:

                <name> — <udid> [BOOTED] (<runtime>)

            The `[BOOTED]` marker is present only for currently booted
            devices. Pipe through grep or fzf to pick a UDID for
            `--device` on run / snapshot.
            """
    )

    @Flag(
        name: .long,
        help: "Emit the simulator list as a JSON array on stdout instead of human text"
    )
    var json: Bool = false

    mutating func run() async throws {
        try await DaemonClient.withDaemonClient(name: "previewsmcp-simulators") { client in
            let response = try await client.callToolStructured(
                name: "simulator_list", arguments: [:]
            )
            if response.isError == true {
                throw DaemonToolError.daemonError(response.content.joinedText())
            }

            if json {
                guard let structured = response.structuredContent else {
                    throw DaemonToolError.daemonError(
                        "simulator_list response missing structuredContent"
                    )
                }
                try emitJSON(structured)
                return
            }

            // Unlike elements (where empty stdout is plausible),
            // `simulator_list` always returns either device lines or the
            // sentinel "No available simulator devices found." — so
            // always surface the daemon's reply verbatim.
            print(response.content.joinedText())
        }
    }
}

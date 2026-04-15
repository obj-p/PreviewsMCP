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

    mutating func run() async throws {
        let client = try await DaemonClient.connect(clientName: "previewsmcp-simulators") { client in
            await client.onNotification(LogMessageNotification.self) { message in
                if case .string(let text) = message.params.data {
                    fputs("\(text)\n", stderr)
                }
            }
        }

        do {
            let response = try await client.callTool(name: "simulator_list", arguments: [:])
            if response.isError == true {
                throw SimulatorsCommandError.daemonError(response.content.joinedText())
            }

            let text = response.content.joinedText()
            if !text.isEmpty { print(text) }

            await client.disconnect()
        } catch {
            await client.disconnect()
            throw error
        }
    }
}

enum SimulatorsCommandError: Error, CustomStringConvertible {
    case daemonError(String)

    var description: String {
        switch self {
        case .daemonError(let text): return text
        }
    }
}

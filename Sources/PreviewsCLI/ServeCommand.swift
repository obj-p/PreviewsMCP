import AppKit
import ArgumentParser
import Foundation
import MCP

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Expose preview tools over MCP (stdio transport)",
        discussion: """
            Runs an MCP server on stdin/stdout that exposes tools for listing,
            launching, configuring, snapshotting, and interacting with SwiftUI
            previews. Intended to be launched by an MCP-compatible client — for
            example, by adding this to `.mcp.json`:

              {
                "mcpServers": {
                  "previews": {
                    "command": "/path/to/previewsmcp",
                    "args": ["serve"]
                  }
                }
              }

            Once connected, the agent can discover the available tools
            (preview_list, preview_start, preview_snapshot, preview_configure,
            preview_switch, preview_variants, preview_elements, preview_touch,
            preview_stop, simulator_list) and their schemas via the standard MCP
            handshake.
            """
    )

    mutating func run() throws {
        Task {
            do {
                let (server, _) = try await configureMCPServer()
                fputs("MCP server starting on stdio...\n", stderr)
                let transport = StdioTransport()
                try await server.start(transport: transport)
            } catch {
                fputs("MCP server error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

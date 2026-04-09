import AppKit
import ArgumentParser
import Foundation
import MCP

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Start MCP server over stdio"
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

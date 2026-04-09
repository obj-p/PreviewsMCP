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
        fputs("serve: ServeCommand.run() entry\n", stderr)
        Task {
            do {
                fputs("serve: configureMCPServer start\n", stderr)
                let (server, _) = try await configureMCPServer()
                fputs("serve: configureMCPServer done; creating transport\n", stderr)
                let transport = StdioTransport()
                fputs("serve: calling server.start()\n", stderr)
                try await server.start(transport: transport)
                fputs("serve: server.start() returned (server is running)\n", stderr)
            } catch {
                fputs("serve: MCP server error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

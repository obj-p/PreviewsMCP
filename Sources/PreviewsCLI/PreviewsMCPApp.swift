import AppKit
import ArgumentParser
import PreviewHost

/// Shared state, accessible from commands.
@MainActor
enum App {
    static let host = PreviewHost()
}

@main
struct PreviewsMCPApp {
    static func main() {
        let command: ParsableCommand
        do {
            command = try PreviewsMCPCommand.parseAsRoot()
        } catch {
            PreviewsMCPCommand.exit(withError: error)
        }

        // ListCommand doesn't need NSApplication
        if command is ListCommand {
            do {
                var mutable = command
                try mutable.run()
            } catch {
                PreviewsMCPCommand.exit(withError: error)
            }
            return
        }

        // Commands needing UI: start NSApplication
        let app = NSApplication.shared
        let host = App.host
        app.delegate = host

        // MCP serve mode: don't quit when last window closes
        if command is ServeCommand {
            host.keepAliveWithoutWindows = true
        }

        host.onLaunch = {
            Task { @MainActor in
                do {
                    var mutable = command
                    try mutable.run()
                } catch {
                    print("Error: \(error)")
                    NSApp.terminate(nil)
                }
            }
        }

        app.run()
    }
}

struct PreviewsMCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previews-mcp",
        abstract: "Run SwiftUI previews outside of Xcode",
        subcommands: [RunCommand.self, ListCommand.self, SnapshotCommand.self, ServeCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

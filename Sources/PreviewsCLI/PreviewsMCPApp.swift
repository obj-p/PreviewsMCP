import AppKit
import ArgumentParser
import PreviewsMacOS

/// Target platform for CLI commands.
enum CLIPlatform: String, ExpressibleByArgument, CaseIterable {
    case macos
    case iosSimulator = "ios-simulator"
}

/// Shared state, accessible from commands. Initialized in main() after command parsing.
@MainActor
enum App {
    static var host: PreviewHost!
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

        // Commands that don't need NSApplication (list, help, etc.)
        if command is ListCommand
            || !(command is RunCommand || command is ServeCommand || command is SnapshotCommand
                || command is PlaygroundCommand)
        {
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

        let mode: PreviewHost.Mode
        if command is ServeCommand {
            mode = .serve
        } else if command is SnapshotCommand {
            mode = .snapshot
        } else {
            mode = .interactive
        }

        let host = PreviewHost(mode: mode)
        App.host = host
        app.delegate = host

        if host.headless {
            app.setActivationPolicy(.accessory)
        }

        host.onLaunch = {
            Task { @MainActor in
                do {
                    var mutable = command
                    try mutable.run()
                } catch {
                    PreviewsMCPCommand.exit(withError: error)
                }
            }
        }

        app.run()
    }
}

struct PreviewsMCPCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "previewsmcp",
        abstract: "Run SwiftUI previews outside of Xcode",
        subcommands: [
            RunCommand.self, ListCommand.self, SnapshotCommand.self, ServeCommand.self, PlaygroundCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}

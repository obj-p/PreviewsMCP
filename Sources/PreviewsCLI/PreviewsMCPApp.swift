import AppKit
import ArgumentParser
import PreviewsMacOS

/// Target platform for CLI commands.
enum CLIPlatform: String, ExpressibleByArgument, CaseIterable {
    case macos
    case iosSimulator = "ios-simulator"
}

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

        // Commands that don't need NSApplication (list, help, etc.)
        if command is ListCommand || !(command is RunCommand || command is ServeCommand || command is SnapshotCommand) {
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

        // Serve and snapshot modes run headless (no Dock icon, off-screen windows)
        if command is ServeCommand || command is SnapshotCommand {
            host.headless = true
            app.setActivationPolicy(.accessory)
        }
        if command is ServeCommand {
            host.keepAliveWithoutWindows = true
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
        subcommands: [RunCommand.self, ListCommand.self, SnapshotCommand.self, ServeCommand.self],
        defaultSubcommand: RunCommand.self
    )
}

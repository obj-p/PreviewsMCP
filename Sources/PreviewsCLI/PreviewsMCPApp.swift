import AppKit
import ArgumentParser
import PreviewsMacOS

/// Target platform for CLI commands.
enum CLIPlatform: String, ExpressibleByArgument, CaseIterable {
    case macos
    case ios
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

        // Commands that don't need NSApplication (list, help, status, kill-daemon)
        if command is ListCommand
            || !(command is RunCommand || command is ServeCommand || command is SnapshotCommand
                || command is VariantsCommand)
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
        } else if command is SnapshotCommand || command is VariantsCommand {
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
    static let version = GeneratedVersion.value

    static let configuration = CommandConfiguration(
        commandName: "previewsmcp",
        abstract: "Render, snapshot, and interact with SwiftUI previews outside of Xcode",
        discussion: """
            Works in two modes:

              • CLI — run, snapshot, or enumerate #Preview blocks directly from
                your shell (run / snapshot / variants / list).
              • MCP server — `previewsmcp serve` exposes the same capabilities as
                tools over stdio for Claude Code, Cursor, or any other
                MCP-compatible agent.

            Supports both #Preview macros and legacy PreviewProvider. Renders on
            macOS via NSHostingView or on a booted iOS simulator, with trait
            overrides, hot reload, accessibility-tree inspection, and touch
            injection.

            Run `previewsmcp help <subcommand>` for full options on each command.
            """,
        version: version,
        subcommands: [
            RunCommand.self, ListCommand.self, SnapshotCommand.self, VariantsCommand.self,
            ServeCommand.self, StatusCommand.self, KillDaemonCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}

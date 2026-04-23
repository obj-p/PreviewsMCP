import AppKit
import ArgumentParser
import PreviewsMacOS

/// Target platform for CLI commands.
enum CLIPlatform: String, ExpressibleByArgument, CaseIterable {
    case macos
    case ios
}

@main
struct PreviewsMCPApp {
    static func main() {
        // Force line-buffered stderr. When previewsmcp runs as a subprocess
        // with stderr redirected to a file (e.g., MCPTestServer captures,
        // or the daemon's ~/.previewsmcp/serve.log), libc stdio switches
        // from line-buffered (TTY default) to fully-buffered (4K blocks).
        // Diagnostic `fputs(..., stderr)` lines then never reach disk
        // until the buffer fills or the process exits cleanly — and if
        // the subprocess is killed (test time-limit, daemon stop), the
        // stage markers we rely on for CI post-mortems are lost.
        setlinebuf(stderr)

        let command: ParsableCommand
        do {
            command = try PreviewsMCPCommand.parseAsRoot()
        } catch {
            PreviewsMCPCommand.exit(withError: error)
        }

        // Every CLI subcommand except `serve` is now a daemon client.
        // Only `serve` drives AppKit directly (it *is* the daemon).
        if !(command is ServeCommand) {
            // Handle async commands: the MCP SDK's NetworkTransport schedules
            // NWConnection callbacks on DispatchQueue.main, so we can't just
            // block main with a semaphore — the callbacks would never fire.
            // Use dispatchMain() to yield to libdispatch and let the async Task
            // drive to completion, then delegate to ParsableCommand.exit()
            // from the Task so error formatting matches the sync branch
            // (ArgumentParser formats ValidationError / ExitCode correctly).
            if let asyncCommand = command as? any AsyncParsableCommand {
                Task {
                    do {
                        var mutable = asyncCommand
                        try await mutable.run()
                        Darwin.exit(0)
                    } catch {
                        PreviewsMCPCommand.exit(withError: error)
                    }
                }
                dispatchMain()  // never returns; Task exits the process
            }

            do {
                var mutable = command
                try mutable.run()
            } catch {
                PreviewsMCPCommand.exit(withError: error)
            }
            return
        }

        // `serve` is the only command that runs AppKit in-process — every
        // other subcommand is now a daemon client.
        let app = NSApplication.shared
        let host = PreviewHost()
        ServeCommand.sharedHost = host
        app.delegate = host

        // Always headless: no Dock icon, windows positioned off-screen.
        app.setActivationPolicy(.accessory)

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
            ConfigureCommand.self, SwitchCommand.self, ElementsCommand.self,
            TouchCommand.self, SimulatorsCommand.self, StopCommand.self,
            ServeCommand.self, StatusCommand.self, LogsCommand.self, KillDaemonCommand.self,
        ],
        defaultSubcommand: RunCommand.self
    )
}

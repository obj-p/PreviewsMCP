import AppKit
import ArgumentParser
import Foundation
import MCP
import PreviewsMacOS

struct ServeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "serve",
        abstract: "Expose preview tools over MCP",
        discussion: """
            Two modes:

              • Stdio (default) — reads MCP JSON-RPC from stdin, writes to stdout.
                Intended for MCP-compatible clients (Claude Code, Cursor) that
                launch `previewsmcp serve` as a subprocess. Example `.mcp.json`:

                  {
                    "mcpServers": {
                      "previews": {
                        "command": "/path/to/previewsmcp",
                        "args": ["serve"]
                      }
                    }
                  }

              • Daemon (`--daemon`) — listens on a Unix domain socket at
                `~/.previewsmcp/serve.sock`. Multiplexes many concurrent preview
                sessions. Used by the CLI (run, snapshot, etc.) and by any
                external MCP client capable of speaking over UDS.

            Both modes expose the same tools: preview_list, preview_start,
            preview_snapshot, preview_configure, preview_switch, preview_variants,
            preview_elements, preview_touch, preview_stop, simulator_list.
            """
    )

    @Flag(name: .long, help: "Run as a daemon on a Unix domain socket instead of stdio")
    var daemon: Bool = false

    /// Set by `PreviewsMCPApp.main()` before `run()` is called. This is
    /// the only handoff point between the entry point (which creates the
    /// PreviewHost) and the serve command (which passes it to the MCP
    /// server). ParsableCommand's `run()` can't take parameters, so a
    /// static is the minimal shared-state mechanism.
    @MainActor static var sharedHost: PreviewHost!

    mutating func run() throws {
        if daemon {
            runDaemon()
        } else {
            runStdio()
        }
    }

    private func runStdio() {
        Task { @MainActor in
            let host = Self.sharedHost!
            do {
                let (server, _) = try await configureMCPServer(host: host)
                fputs("MCP server starting on stdio...\n", stderr)
                let transport = StdioTransport()
                try await server.start(transport: transport)
            } catch {
                fputs("MCP server error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    private func runDaemon() {
        Task { @MainActor in
            do {
                // Liveness check via `connect()` is authoritative — the PID file
                // alone can be stale (deleted while daemon is still running) or
                // missing during the brief window between bind and PID write.
                // Without this check, a second daemon would unlink the first's
                // socket file and attempt to rebind, corrupting the running
                // system.
                if DaemonProbe.canConnect() {
                    let pidDesc =
                        DaemonLifecycle.daemonRunningPID().map { "pid \($0)" }
                        ?? "pid unknown"
                    fputs(
                        "daemon already running (\(pidDesc)); "
                            + "use `previewsmcp kill-daemon` first\n",
                        stderr
                    )
                    Darwin.exit(1)
                }

                // Detach before any client can observe us as "ready" via the
                // socket. Otherwise a SIGHUP during the tiny window between
                // socket bind and setsid could cascade through the shared
                // process group and kill the daemon.
                DaemonLifecycle.detachFromTerminal()

                let host = Self.sharedHost!
                _ = try await DaemonListener.start(host: host)
                try DaemonLifecycle.register()
                fputs(
                    "daemon ready (pid \(ProcessInfo.processInfo.processIdentifier))\n",
                    stderr
                )
            } catch {
                fputs("daemon startup failed: \(error)\n", stderr)
                DaemonLifecycle.unregister()
                Darwin.exit(1)
            }
        }
    }
}

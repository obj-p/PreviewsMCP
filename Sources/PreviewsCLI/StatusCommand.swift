import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the previewsmcp daemon is running"
    )

    @Flag(
        name: .long,
        help: "Emit daemon status as a JSON document on stdout"
    )
    var json: Bool = false

    func run() throws {
        let alive = DaemonProbe.canConnect()
        let pid = DaemonLifecycle.daemonRunningPID()

        if json {
            let state: String =
                alive
                ? "running"
                : (pid != nil ? "transitional" : "stopped")
            try emitJSON(
                StatusJSONOutput(
                    state: state,
                    running: alive,
                    pid: pid,
                    socketPath: DaemonPaths.socket.path
                )
            )
            if !alive && pid == nil { throw ExitCode(1) }
            return
        }

        if alive {
            let pidDesc = pid.map { "pid \($0)" } ?? "pid unknown"
            print("daemon running (\(pidDesc))")
            print("  socket: \(DaemonPaths.socket.path)")
        } else if let pid {
            // Process alive but socket not accepting — likely mid-startup or shutdown.
            print("daemon starting or shutting down (pid \(pid))")
        } else {
            print("daemon not running")
            throw ExitCode(1)
        }
    }
}

/// `status --json` mode output. Synthesized client-side; `status` has no
/// backing MCP tool.
struct StatusJSONOutput: Encodable {
    /// "running" | "transitional" | "stopped".
    let state: String
    let running: Bool
    let pid: Int32?
    let socketPath: String
}

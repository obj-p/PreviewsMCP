import ArgumentParser
import Foundation

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the previewsmcp daemon is running"
    )

    func run() throws {
        let alive = DaemonProbe.canConnect()
        let pid = DaemonLifecycle.daemonRunningPID()

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

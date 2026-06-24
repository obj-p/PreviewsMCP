import ArgumentParser
import Foundation

struct KillDaemonCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "kill-daemon",
        abstract: "Stop the running previewsmcp daemon"
    )

    @Option(name: .long, help: "Seconds to wait for graceful shutdown before giving up")
    var timeout: Double = 5.0

    func run() throws {
        guard let pid = DaemonLifecycle.readPID() else {
            print("daemon not running (no PID file)")
            return
        }

        guard DaemonLifecycle.isProcessAlive(pid) else {
            print("daemon not running (stale PID \(pid))")
            DaemonLifecycle.unregister()
            return
        }

        // Send SIGTERM for graceful shutdown.
        guard kill(pid, SIGTERM) == 0 else {
            let reason = String(cString: strerror(errno))
            print("failed to signal daemon (pid \(pid)): \(reason)")
            throw ExitCode(1)
        }

        // Poll until the process is gone or timeout elapses.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !DaemonLifecycle.isProcessAlive(pid) {
                print("daemon stopped (pid \(pid))")
                return
            }
            Thread.sleep(forTimeInterval: 0.1)
        }

        print("daemon did not exit within \(timeout)s; leaving it running")
        throw ExitCode(1)
    }
}

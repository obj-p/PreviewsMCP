import ArgumentParser
import Darwin
import Foundation
import VZKit

/// `boot` blocks; `stop` signals it from another shell. SIGTERM lands on
/// `SignalWaiter` in the boot process which then calls
/// `requestStop`/`waitForStop` and exits cleanly.
struct StopCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Signal a running boot to shut the VM down."
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Seconds to wait for the boot PID to exit before returning.")
    var waitTimeout: Double = 90

    @Flag(name: .long, help: "SIGKILL instead of SIGTERM (no graceful guest shutdown).")
    var force: Bool = false

    func run() async throws {
        let bundle = try bundle.load()
        guard let pid = VMPidFile.read(bundle) else {
            Log.info("no PID file at \(bundle.pidFileURL.path) — nothing to stop")
            return
        }
        guard VMPidFile.isAlive(pid) else {
            Log.info("PID \(pid) is not alive; clearing stale PID file")
            VMPidFile.clear(bundle)
            return
        }

        let signal: Int32 = force ? SIGKILL : SIGTERM
        Log.info("sending \(force ? "SIGKILL" : "SIGTERM") to boot PID \(pid)")
        if kill(pid, signal) != 0 {
            let err = String(cString: strerror(errno))
            throw VMError("kill(\(pid), \(signal)) failed: \(err)")
        }

        let deadline = Date().addingTimeInterval(waitTimeout)
        while Date() < deadline {
            if !VMPidFile.isAlive(pid) {
                Log.info("boot PID \(pid) exited")
                return
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw VMError("boot PID \(pid) did not exit within \(Int(waitTimeout))s")
    }
}

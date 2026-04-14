import ArgumentParser
import Foundation
import Network

/// Thread-safe boolean for the connection result. Needed because the
/// NWConnection state handler is a @Sendable closure that runs on a
/// background queue.
private final class ConnectResult: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = false
    var value: Bool {
        lock.lock(); defer { lock.unlock() }
        return _value
    }
    func set(_ v: Bool) {
        lock.lock(); _value = v; lock.unlock()
    }
}

struct StatusCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "status",
        abstract: "Report whether the previewsmcp daemon is running"
    )

    func run() throws {
        let pid = DaemonLifecycle.readPID()
        let socketReachable = canConnectToDaemon()

        switch (pid, socketReachable) {
        case (let pid?, true) where DaemonLifecycle.isProcessAlive(pid):
            print("daemon running (pid \(pid))")
            print("  socket: \(DaemonPaths.socket.path)")
        case (.some, true), (.none, true):
            // Socket reachable without a PID or with a dead PID — unusual, still report.
            print("daemon running (pid unknown)")
            print("  socket: \(DaemonPaths.socket.path)")
        case (let pid?, false) where DaemonLifecycle.isProcessAlive(pid):
            // Process alive but socket unreachable. Likely in the middle of startup or shutdown.
            print("daemon starting or shutting down (pid \(pid))")
        default:
            print("daemon not running")
            Self.exit(withError: ExitCode(1))
        }
    }

    /// Try to connect to the daemon socket with a short timeout.
    /// Returns true if a connection is established, false otherwise.
    private func canConnectToDaemon() -> Bool {
        guard FileManager.default.fileExists(atPath: DaemonPaths.socket.path) else {
            return false
        }

        let connection = NWConnection(
            to: NWEndpoint.unix(path: DaemonPaths.socket.path),
            using: .tcp
        )
        let semaphore = DispatchSemaphore(value: 0)
        let result = ConnectResult()

        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                result.set(true)
                semaphore.signal()
            case .failed, .cancelled:
                semaphore.signal()
            default:
                break
            }
        }
        connection.start(queue: .global())
        _ = semaphore.wait(timeout: .now() + 1)
        connection.cancel()
        return result.value
    }
}

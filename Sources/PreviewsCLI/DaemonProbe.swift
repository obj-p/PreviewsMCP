import Foundation
import Network

/// Liveness check for the daemon: can we connect to its socket?
///
/// This is the canonical "is the daemon running?" test. The kernel atomically
/// tracks socket-to-fd associations, so if `connect()` succeeds, something is
/// listening. A lingering `serve.sock` file from a crashed daemon returns
/// ECONNREFUSED, so socket file presence alone is not enough.
///
/// Used by:
/// - `ServeCommand --daemon` before unlinking a stale socket, to avoid
///   clobbering a running daemon whose PID file was deleted.
/// - `StatusCommand` for its liveness report.
/// - `DaemonClient` (PR 2) as the auto-start trigger.
enum DaemonProbe {

    /// Try to connect to the daemon socket with a short timeout.
    /// Returns true on success, false on ENOENT / ECONNREFUSED / timeout.
    static func canConnect(timeout: TimeInterval = 1.0) -> Bool {
        // Fast path: if the socket file doesn't exist, no daemon is listening.
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
        _ = semaphore.wait(timeout: .now() + timeout)
        connection.cancel()
        return result.value
    }
}

/// Thread-safe boolean set from the NWConnection state handler (runs on a
/// background queue) and read from the main thread.
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

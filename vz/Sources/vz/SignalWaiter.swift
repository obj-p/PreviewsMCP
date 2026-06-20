import Darwin
import Dispatch
import Foundation

/// Suspend an async caller until SIGINT or SIGTERM arrives. Used by `boot`
/// to keep the VM running in the foreground until the user hits ^C or
/// another shell sends SIGTERM via `stop`.
///
/// Why the dispatcher: `DispatchSourceSignal` event handlers fire on a
/// dispatch queue (main here), and we need to bridge that one-shot event
/// to a `CheckedContinuation`. Wrapping it in a class lets the
/// `@unchecked Sendable` annotation document that the lock guarantees
/// safety across the queue boundary.
enum SignalWaiter {
    static func waitForTerminationSignal() async -> Int32 {
        await withCheckedContinuation { continuation in
            SignalDispatcher.shared.arm(
                signals: [SIGINT, SIGTERM], continuation: continuation)
        }
    }
}

private final class SignalDispatcher: @unchecked Sendable {
    static let shared = SignalDispatcher()
    private let lock = NSLock()
    private var sources: [DispatchSourceSignal] = []
    private var continuation: CheckedContinuation<Int32, Never>?

    func arm(signals: [Int32], continuation: CheckedContinuation<Int32, Never>) {
        lock.lock()
        guard self.continuation == nil else {
            lock.unlock()
            // Only one outstanding waiter is ever needed for our CLI;
            // duplicate calls return a sentinel rather than clobber.
            continuation.resume(returning: -1)
            return
        }
        self.continuation = continuation
        for sig in signals {
            Darwin.signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in
                self?.fire(sig: sig)
            }
            src.resume()
            sources.append(src)
        }
        lock.unlock()
    }

    private func fire(sig: Int32) {
        lock.lock()
        let cont = continuation
        continuation = nil
        let toCancel = sources
        sources = []
        lock.unlock()
        for s in toCancel { s.cancel() }
        cont?.resume(returning: sig)
    }
}

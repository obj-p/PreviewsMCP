import Dispatch
import os
import System

/// Kernel readiness for non-blocking descriptors (pre-stage-5 requirement:
/// the daemon must not idle-poll at 100Hz per connection). Callers attempt
/// the syscall first and wait only on EAGAIN, so descriptors that cannot
/// EAGAIN (regular files, /dev/null) and error paths (EBADF) never reach
/// the source machinery; kqueue readiness is level-triggered, so bytes
/// arriving between the EAGAIN and activation still fire the event.
enum FDReadiness {
    static func waitUntilReadable(_ descriptor: FileDescriptor) async throws {
        let source = DispatchSource.makeReadSource(
            fileDescriptor: descriptor.rawValue, queue: .global()
        )
        let resumed = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                source.setEventHandler {
                    guard resumed.withLock({ claimed in
                        if claimed { return false }
                        claimed = true
                        return true
                    }) else { return }
                    source.cancel()
                    cont.resume()
                }
                source.setCancelHandler {
                    guard resumed.withLock({ claimed in
                        if claimed { return false }
                        claimed = true
                        return true
                    }) else { return }
                    cont.resume(throwing: CancellationError())
                }
                source.activate()
            }
        } onCancel: {
            source.cancel()
        }
    }
}

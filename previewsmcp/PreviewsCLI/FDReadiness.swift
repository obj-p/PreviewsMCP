import Dispatch
import os
import System

/// Kernel readiness for non-blocking descriptors (pre-stage-5 requirement:
/// the daemon must not idle-poll at 100Hz per connection). Callers attempt
/// the syscall first and wait only on EAGAIN, so descriptors that cannot
/// EAGAIN (regular files, /dev/null) and error paths (EBADF) never reach
/// the source machinery; kqueue readiness is level-triggered, so bytes
/// arriving between the EAGAIN and activation still fire the event.
///
/// The source's cancellation handler is the ONLY resume point: Dispatch
/// runs it after the kqueue registration is torn down, so when the wait
/// returns, nothing kernel-side still references the descriptor — the
/// transport's owner-may-close-after-disconnect contract depends on that
/// ordering.
enum FDReadiness {
    static func waitUntilReadable(_ descriptor: FileDescriptor) async throws {
        try await wait(on: DispatchSource.makeReadSource(fileDescriptor: descriptor.rawValue))
    }

    static func waitUntilWritable(_ descriptor: FileDescriptor) async throws {
        try await wait(on: DispatchSource.makeWriteSource(fileDescriptor: descriptor.rawValue))
    }

    private static func wait(on source: some DispatchSourceProtocol) async throws {
        nonisolated(unsafe) let source = source
        let taskCancelled = OSAllocatedUnfairLock(initialState: false)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                source.setEventHandler {
                    source.cancel()
                }
                source.setCancelHandler {
                    if taskCancelled.withLock({ $0 }) {
                        cont.resume(throwing: CancellationError())
                    } else {
                        cont.resume()
                    }
                }
                source.activate()
            }
        } onCancel: {
            taskCancelled.withLock { $0 = true }
            source.cancel()
        }
    }
}

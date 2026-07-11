import Dispatch
import System

/// Kernel readiness for non-blocking descriptors (pre-stage-5 requirement:
/// the daemon must not idle-poll at 100Hz per connection). Callers attempt
/// the syscall first and wait only on EAGAIN; the wait returns — without
/// signalling why — when the descriptor is ready, when the surrounding
/// task is cancelled, or after a 1s safety interval, and the caller's
/// re-attempted syscall plus its own cancellation checks decide what
/// happened. kqueue readiness is level-triggered, so bytes arriving
/// between the EAGAIN and activation still fire the event.
///
/// The 1s re-attempt bounds every failure kqueue cannot report: an fd
/// closed mid-wait drops its knote silently (the old 10ms poll surfaced
/// EBADF; this wakes and re-reads within a second), and device fds kqueue
/// cannot watch degrade to a 1Hz poll instead of hanging.
///
/// The source's cancellation handler is the ONLY resume point: Dispatch
/// runs it after the kqueue registration is torn down, so when the wait
/// returns, nothing kernel-side still references the descriptor — the
/// transport's owner-may-close-after-disconnect contract depends on that
/// ordering.
enum FDReadiness {
    static func waitUntilReadable(_ descriptor: FileDescriptor) async {
        await wait(on: DispatchSource.makeReadSource(fileDescriptor: descriptor.rawValue))
    }

    static func waitUntilWritable(_ descriptor: FileDescriptor) async {
        await wait(on: DispatchSource.makeWriteSource(fileDescriptor: descriptor.rawValue))
    }

    private static let reattemptInterval: DispatchTimeInterval = .seconds(1)

    private static func wait(on source: some DispatchSourceProtocol & SendableMetatype) async {
        nonisolated(unsafe) let source = source
        await withTaskCancellationHandler {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                source.setEventHandler {
                    source.cancel()
                }
                source.setCancelHandler {
                    cont.resume()
                }
                source.activate()
                DispatchQueue.global().asyncAfter(deadline: .now() + reattemptInterval) {
                    source.cancel()
                }
            }
        } onCancel: {
            source.cancel()
        }
    }
}

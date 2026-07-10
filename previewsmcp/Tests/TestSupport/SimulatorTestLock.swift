import Foundation

/// Host-level serialization for simulator-booting tests (#336).
///
/// `DaemonTestLock` serializes suites within one workspace (its flock path is
/// keyed by `$TEST_TMPDIR`) and Bazel's `exclusive` tag serializes targets
/// within one invocation, but two checkouts/worktrees running sim-booting
/// suites concurrently share the host's single CoreSimulator service and
/// degrade it for both. This lock closes that gap: a blocking flock on a
/// fixed per-user path, so any workspace's sim-booting tests queue behind
/// each other machine-wide.
///
/// Ordering: acquire this lock BEFORE `DaemonTestLock`. Sim-booting daemon
/// tests hold both; daemon-only tests hold only `DaemonTestLock`, so no
/// cycle is possible. Waiting for the lock counts against a test's
/// `.timeLimit`, which is the intent — queueing behind another workspace's
/// sim work is strictly better than racing it.
///
/// Uses a blocking flock on a detached thread (same rationale as
/// `DaemonTestLock`): non-blocking polling from Swift concurrency starves
/// small cooperative pools.
public enum SimulatorTestLock {
    private static var lockPath: String {
        (NSHomeDirectory() as NSString).appendingPathComponent(".previewsmcp/sim.lock")
    }

    /// A held exclusive lock. Call `release()` to let the next waiter proceed;
    /// pair it with `defer` at the acquisition site.
    public final class Guard: Sendable {
        private let fd: Int32
        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        public func release() {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Block until the host-wide simulator lock is held, then return a `Guard`
    /// the caller releases (via `defer`) when its critical section ends.
    public static func acquire() async throws -> Guard {
        let path = lockPath
        let fd = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "open(\(path)) failed",
                            ]
                        )
                    )
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "flock failed",
                            ]
                        )
                    )
                    return
                }
                cont.resume(returning: fd)
            }
        }
        return Guard(fd: fd)
    }
}

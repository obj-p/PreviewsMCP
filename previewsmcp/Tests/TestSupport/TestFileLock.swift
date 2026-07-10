import Foundation

/// Blocking-flock primitive behind the test-side locks (`SimulatorTestLock`
/// and both suites' `DaemonTestLock`).
///
/// Acquisition runs on a detached thread: a blocking flock on Swift
/// concurrency's cooperative pool starves small pools, and the earlier
/// non-blocking poll approach deadlocked CI runners whose N-1 polling tasks
/// consumed every thread.
///
/// `O_CLOEXEC` is load-bearing: tests spawn children (daemons, `simctl`,
/// sim executables) while holding a lock, and an inherited dup of the fd
/// would keep the kernel flock held after a test process dies without
/// unlocking — see `DaemonRestart.acquireRestartLock` and issue #142.
public enum TestFileLock {
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

    /// Block until the exclusive lock on `path` is held, then return a
    /// `Guard` the caller releases when its critical section ends.
    public static func acquire(_ path: String) async throws -> Guard {
        let fd = try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
                let fd = open(path, O_CREAT | O_RDWR | O_CLOEXEC, 0o644)
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

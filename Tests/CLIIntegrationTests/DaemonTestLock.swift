import Foundation

/// Cross-suite serialization for daemon-touching integration tests.
///
/// Uses a blocking flock on a detached thread to avoid starving
/// Swift's cooperative thread pool. The previous approach (non-
/// blocking flock + Task.sleep polling) caused deadlocks on CI
/// runners with small thread pools: N-1 polling tasks consumed all
/// threads, preventing the lock-holding task's subprocess
/// completion handlers from firing.
enum DaemonTestLock {

    private static let lockPath: String =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("previewsmcp-daemon-test.lock").path

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        // Acquire the lock on a non-cooperative thread so we don't
        // block the Swift concurrency thread pool.
        let fd = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "open(\(lockPath)) failed"
                            ]))
                    return
                }
                // Blocking flock — this thread sleeps in the kernel
                // until the lock is available. Does NOT consume a
                // cooperative thread.
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey:
                                    "flock failed"
                            ]))
                    return
                }
                cont.resume(returning: fd)
            }
        }

        let result: Swift.Result<T, Error>
        do {
            result = .success(try await body())
        } catch {
            result = .failure(error)
        }

        _ = flock(fd, LOCK_UN)
        close(fd)
        return try result.get()
    }
}

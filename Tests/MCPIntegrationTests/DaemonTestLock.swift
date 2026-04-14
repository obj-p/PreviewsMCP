import Foundation

/// Filesystem lock to serialize daemon-touching tests across suites and test
/// targets. Swift Testing's `.serialized` trait only orders tests within its
/// own suite; two suites (even in the same process) can run in parallel and
/// stomp on each other's daemon.
///
/// The lock is advisory (`flock`) on a well-known path. Tests acquire the
/// lock before any daemon interaction and release it when the test body
/// returns. A crashed test releases the lock when its file descriptor
/// closes on process exit.
///
/// Duplicated in both CLIIntegrationTests and MCPIntegrationTests because
/// Swift test targets can't share source files.
enum DaemonTestLock {

    static let lockPath: String =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("previewsmcp-daemon-test.lock").path

    /// Acquire the lock, run the given async body, release the lock.
    /// Blocks (via polling) until the lock is available.
    static func run<T>(body: () async throws -> T) async throws -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [NSLocalizedDescriptionKey: "open(\(lockPath)) failed: \(String(cString: strerror(errno)))"]
            )
        }
        defer { close(fd) }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [NSLocalizedDescriptionKey: "flock failed: \(String(cString: strerror(errno)))"]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try await body()
    }
}

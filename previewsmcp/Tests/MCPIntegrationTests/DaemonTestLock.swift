import Foundation

/// Cross-suite serialization for MCP integration tests.
/// See CLIIntegrationTests/DaemonTestLock.swift for rationale.
enum DaemonTestLock {
    @TaskLocal static var socketDir: String?

    private static var lockPath: String {
        let dir =
            ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"]
                ?? FileManager.default.temporaryDirectory.path
        return (dir as NSString).appendingPathComponent("previewsmcp-daemon-test.lock")
    }

    /// A held exclusive lock. Call `release()` to let the next waiter proceed;
    /// pair it with `defer` at the acquisition site.
    final class Guard: Sendable {
        private let fd: Int32
        fileprivate init(fd: Int32) {
            self.fd = fd
        }

        func release() {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }
    }

    /// Block until the cross-suite lock is held, then return a `Guard` the
    /// caller releases (via `defer`) when its critical section ends.
    static func acquire() async throws -> Guard {
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

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        let lock = try await acquire()
        defer { lock.release() }
        return try await body()
    }
}

import Foundation

/// Cross-suite serialization for daemon-touching integration tests.
///
/// Swift Testing's `.serialized` trait only orders tests within a
/// suite. Two suites can run in parallel and stomp on each other's
/// daemon. The flock serializes all daemon-touching tests across
/// suites and test targets.
///
/// Tests share one daemon at `~/.previewsmcp/serve.sock`. Each suite
/// calls `cleanSlate()` once at the start to kill any leftover daemon
/// from a previous suite; the daemon auto-starts on the first CLI
/// command and persists for the rest of the suite.
enum DaemonTestLock {

    private static let lockPath: String =
        FileManager.default.temporaryDirectory
        .appendingPathComponent("previewsmcp-daemon-test.lock").path

    static func run<T>(body: () async throws -> T) async throws -> T {
        let fd = open(lockPath, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            throw NSError(
                domain: NSPOSIXErrorDomain, code: Int(errno),
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "open(\(lockPath)) failed: \(String(cString: strerror(errno)))"
                ]
            )
        }
        defer { close(fd) }

        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK {
                throw NSError(
                    domain: NSPOSIXErrorDomain, code: Int(errno),
                    userInfo: [
                        NSLocalizedDescriptionKey:
                            "flock failed: \(String(cString: strerror(errno)))"
                    ]
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        defer { _ = flock(fd, LOCK_UN) }

        return try await body()
    }
}

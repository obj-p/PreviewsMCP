import Foundation

/// Cross-suite serialization for daemon-touching integration tests.
/// Duplicate of CLIIntegrationTests/DaemonTestLock.swift — Swift test
/// targets can't share source files.
enum DaemonTestLock {

    @TaskLocal static var socketDir: String?

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

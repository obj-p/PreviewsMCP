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

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        let path = lockPath
        let fd = try await withCheckedThrowingContinuation {
            (cont: CheckedContinuation<Int32, Error>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let dir = (path as NSString).deletingLastPathComponent
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true)
                let fd = open(path, O_CREAT | O_RDWR, 0o644)
                guard fd >= 0 else {
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "open(\(path)) failed"
                            ]))
                    return
                }
                if flock(fd, LOCK_EX) != 0 {
                    close(fd)
                    cont.resume(
                        throwing: NSError(
                            domain: NSPOSIXErrorDomain, code: Int(errno),
                            userInfo: [
                                NSLocalizedDescriptionKey: "flock failed"
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

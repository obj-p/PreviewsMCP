import Foundation

/// Per-test daemon isolation with cross-suite serialization.
/// See CLIIntegrationTests/DaemonTestLock.swift for rationale.
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

        let id = UUID().uuidString.prefix(8)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmcp-\(id)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )

        let result: Swift.Result<T, Error>
        do {
            let value = try await $socketDir.withValue(dir.path) {
                try await body()
            }
            result = .success(value)
        } catch {
            result = .failure(error)
        }

        // Kill daemon.
        do {
            let proc = Process()
            proc.executableURL = URL(
                fileURLWithPath: DaemonLifecycleTests.binaryPath)
            proc.arguments = ["kill-daemon", "--timeout", "5"]
            var env = ProcessInfo.processInfo.environment
            env["PREVIEWSMCP_SOCKET_DIR"] = dir.path
            proc.environment = env
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice
            try proc.run()
            proc.waitUntilExit()
        } catch {}

        // SIGKILL fallback.
        let pidFile = dir.appendingPathComponent("serve.pid")
        if let pidStr = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(pidStr.trimmingCharacters(in: .whitespacesAndNewlines))
        {
            if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        }

        try? FileManager.default.removeItem(at: dir)
        return try result.get()
    }
}

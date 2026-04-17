import Foundation

/// Per-suite daemon isolation for MCP integration tests.
///
/// Each test gets its own temp socket directory. Cleanup is
/// aggressive: SIGTERM via CLI, then SIGKILL via PID file fallback.
enum DaemonTestLock {

    @TaskLocal static var socketDir: String?

    static func run<T>(body: () async throws -> T) async throws -> T {
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

        // Kill daemon via CLI.
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
            if kill(pid, 0) == 0 {
                kill(pid, SIGKILL)
            }
        }

        try? FileManager.default.removeItem(at: dir)

        return try result.get()
    }
}

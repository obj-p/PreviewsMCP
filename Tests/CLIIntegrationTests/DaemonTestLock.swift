import Foundation

/// Per-suite daemon isolation for integration tests.
///
/// Each test gets its own temp socket directory so suites run in
/// parallel. Cleanup is aggressive: kill-daemon via CLI, then
/// SIGKILL fallback via PID file, to prevent orphan daemons on CI.
enum DaemonTestLock {

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
            let value = try await CLIRunner.$socketDir.withValue(dir.path) {
                try await body()
            }
            result = .success(value)
        } catch {
            result = .failure(error)
        }

        // Kill any daemon that was auto-started in this directory.
        _ = try? await CLIRunner.$socketDir.withValue(dir.path) {
            try await CLIRunner.run("kill-daemon", arguments: ["--timeout", "5"])
        }

        // SIGKILL fallback: if the daemon didn't exit gracefully,
        // read its PID file and force-kill. Prevents orphans on CI.
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

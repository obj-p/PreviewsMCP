import Foundation

/// Per-suite daemon isolation for MCP integration tests.
///
/// Each test gets its own temp socket directory so suites run in
/// parallel without contention. Sets `PREVIEWSMCP_SOCKET_DIR` in
/// the current task's environment context; callers that spawn the
/// daemon binary must pass this env var through.
enum DaemonTestLock {

    /// The current suite's isolated socket directory path, if set.
    @TaskLocal static var socketDir: String?

    /// Run the body with an isolated daemon socket directory.
    static func run<T>(body: () async throws -> T) async throws -> T {
        // Short name to stay under macOS's 104-byte Unix socket path limit.
        let id = UUID().uuidString.prefix(8)
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pmcp-\(id)")
        try FileManager.default.createDirectory(
            at: dir, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        return try await $socketDir.withValue(dir.path) {
            try await body()
        }
    }
}

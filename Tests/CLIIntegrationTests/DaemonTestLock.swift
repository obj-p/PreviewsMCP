import Foundation

/// Per-suite daemon isolation for integration tests.
///
/// Instead of a global flock that serializes all daemon-touching tests
/// into a single chain, each test suite gets its own socket directory.
/// The daemon spawned by that suite binds to an isolated socket, so
/// suites run in parallel with no contention.
///
/// Usage: wrap each test body in `DaemonTestLock.run { ... }`. The
/// name is kept for source compatibility — internally it sets
/// `CLIRunner.socketDir` via `@TaskLocal`.
enum DaemonTestLock {

    /// Run the body with an isolated daemon socket directory.
    /// Each call creates a unique temp directory and sets
    /// `PREVIEWSMCP_SOCKET_DIR` so the spawned daemon and CLI
    /// commands use suite-specific IPC paths.
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

        return try await CLIRunner.$socketDir.withValue(dir.path) {
            try await body()
        }
    }
}

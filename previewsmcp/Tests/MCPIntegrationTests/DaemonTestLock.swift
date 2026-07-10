import Foundation
import PreviewsTestSupport

/// Cross-suite serialization for MCP integration tests.
/// Locking mechanics live in `TestFileLock` (TestSupport).
enum DaemonTestLock {
    @TaskLocal static var socketDir: String?

    static var effectiveSocketDir: String {
        DaemonTestPaths.effectiveSocketDir
    }

    typealias Guard = TestFileLock.Guard

    /// Block until the cross-suite lock is held, then return a `Guard` the
    /// caller releases (via `defer`) when its critical section ends.
    static func acquire() async throws -> Guard {
        try await TestFileLock.acquire(DaemonTestPaths.daemonLockPath)
    }

    static func run<T: Sendable>(body: @Sendable () async throws -> T) async throws -> T {
        let lock = try await acquire()
        defer { lock.release() }
        return try await body()
    }
}

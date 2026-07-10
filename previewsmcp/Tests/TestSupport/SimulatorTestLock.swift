import Foundation

/// Host-level serialization for simulator-booting tests (#336).
///
/// `DaemonTestLock` serializes suites within one workspace (its flock path is
/// keyed by `$TEST_TMPDIR`) and Bazel's `exclusive` tag serializes targets
/// within one invocation, but two checkouts/worktrees running sim-booting
/// suites concurrently share the host's single CoreSimulator service and
/// degrade it for both. This lock closes that gap: a blocking flock on a
/// fixed per-user path, so any workspace's sim-booting tests queue behind
/// each other machine-wide. `tools/simlock` locks the same path for
/// examples/ integration runs and ad-hoc shell workloads (#345); the two
/// path literals must stay in lockstep (guarded by `LockPathParityTests`).
///
/// Ordering: acquire this lock BEFORE `DaemonTestLock`. Sim-booting daemon
/// tests hold both; daemon-only tests hold only `DaemonTestLock`, so no
/// cycle is possible. Waiting for the lock counts against a test's
/// `.timeLimit`, which is the intent — queueing behind another workspace's
/// sim work is strictly better than racing it.
public enum SimulatorTestLock {
    public static let lockPath =
        (NSHomeDirectory() as NSString).appendingPathComponent(".previewsmcp/sim.lock")

    public typealias Guard = TestFileLock.Guard

    /// Block until the host-wide simulator lock is held, then return a `Guard`
    /// the caller releases (via `defer`) when its critical section ends.
    public static func acquire() async throws -> Guard {
        try await TestFileLock.acquire(lockPath)
    }
}

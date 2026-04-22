import Foundation

/// Tracks the time since the last observed transport activity. Used by
/// `DaemonClient.withDaemonClient` to distinguish "daemon is busy with a
/// long operation" from "daemon is wedged". Any MCP notification arriving
/// on the client's transport bumps the timer via `bump()`; if no bump
/// happens within `threshold`, `waitForStall(threshold:)` returns `true`
/// and the caller forces a transport disconnect so pending `callTool`
/// continuations resume with an error instead of hanging forever.
///
/// Pairs with Phase 1's daemon-global `logger: "heartbeat"` ping (2s
/// cadence) to let a 30s threshold absorb ~15 missed beats before
/// declaring stall — well beyond any reasonable scheduling jitter.
///
/// Scope caveat: actor isolation means `waitForStall` runs on Swift
/// concurrency; if the cooperative thread pool itself is starved
/// (the pattern issue #135 documents), this timer also doesn't fire.
/// That case is covered on the test side by Phase 3's pthread-based
/// `MCPTestServer.withTimeout`. In production (CLI + MCP agents), no
/// sustained starvation source exists, so this level of protection
/// is sufficient.
actor StallTimer {
    private var lastActivity: ContinuousClock.Instant

    init() {
        self.lastActivity = .now
    }

    /// Reset the inactivity counter. Called from every registered
    /// notification handler.
    func bump() {
        lastActivity = .now
    }

    /// Returns `true` when `ContinuousClock.now - lastActivity >= threshold`.
    /// Returns `false` if the containing Task is cancelled before the
    /// threshold is reached.
    ///
    /// The poll sleeps for the remaining time until the deadline, so a
    /// freshly bumped timer waits close to the full `threshold` rather
    /// than busy-looping on a short tick.
    ///
    /// Cancellation must be checked *before* the elapsed/threshold compare
    /// on every iteration. Otherwise a Task cancelled at or after the
    /// threshold boundary would return `true` (stall) instead of `false`
    /// (cancelled), violating the contract on paths where the bump loop
    /// and cancellation race.
    func waitForStall(threshold: Duration) async -> Bool {
        while true {
            if Task.isCancelled { return false }
            let elapsed = ContinuousClock.now - lastActivity
            if elapsed >= threshold { return true }
            let remaining = threshold - elapsed
            do {
                try await Task.sleep(for: remaining)
            } catch {
                // `Task.sleep` only throws on cancellation; short-circuit
                // rather than re-entering the loop (where the elapsed
                // check might win ahead of the cancellation check).
                return false
            }
        }
    }
}

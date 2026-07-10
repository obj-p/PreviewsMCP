import Foundation
import Testing

/// Tests for the test harness itself (`MCPTestServer.withTimeout`), not
/// product code — separate from the suites that exercise the daemon.
@Suite("MCPTestServer harness")
struct MCPTestServerHarnessTests {
    // MARK: - Timeout primitive

    /// Regression guard for `MCPTestServer.withTimeout`. The prior
    /// implementation used `withThrowingTaskGroup` + `Task.sleep(for:)`,
    /// which does not fire when the cooperative thread pool is starved by
    /// a busy-spin in the body — the pattern that caused CI runs
    /// 72323677364, 72328816376, and 72345678664 to go silent for ten
    /// minutes and then be killed by Swift Testing's outer `.timeLimit`.
    /// The replacement uses a detached `Thread` (pthread) timer and
    /// resumes a shared `CheckedContinuation` directly, both of which
    /// sidestep Swift concurrency scheduling.
    ///
    /// The body blocks via POSIX `sleep(3)` — a kernel-level blocking call
    /// that holds its cooperative thread without yielding. Under that
    /// condition the `Task.sleep`-based implementation would silently
    /// miss its deadline; the pthread implementation fires and resumes
    /// the outer continuation. `Thread.sleep(forTimeInterval:)` is
    /// annotated unavailable in async contexts in newer toolchains; plain
    /// `sleep()` has no such annotation and is equivalent for this test.
    @Test(
        "withTimeout pthread timer fires under cooperative-pool starvation",
        .timeLimit(.minutes(3))
    )
    func withTimeoutFiresUnderStarvation() async throws {
        // The pthread calls `process.terminate()` on timeout; a harmless
        // long-running subprocess gives it a real target without pulling
        // in the full MCPTestServer lifecycle (which would entangle this
        // test with MCP-client state that isn't under test here).
        //
        // Route stdio to /dev/null to match MCPTestServer.start()'s hardened
        // pattern (see its comment on inherited stderr wedging CI runners
        // on macOS 15). `/bin/sleep` is silent in practice, but leaking
        // child handles has bitten this codebase before.
        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummy.arguments = ["60"]
        dummy.standardInput = FileHandle.nullDevice
        dummy.standardOutput = FileHandle.nullDevice
        dummy.standardError = FileHandle.nullDevice
        try dummy.run()
        defer {
            if dummy.isRunning { dummy.terminate() }
        }

        let budget = Duration.seconds(2)
        let start = ContinuousClock.now
        await #expect(throws: Error.self) {
            _ = try await MCPTestServer.withTimeout(budget, process: dummy) {
                // Occupy a cooperative thread without yielding. This is
                // the condition the pthread timer is built to survive.
                sleep(60)
                return ()
            }
        }
        let elapsed = (ContinuousClock.now - start).asTimeInterval

        // Upper bound absorbs thread-creation + continuation-resume
        // overhead. If the timer doesn't fire at all, the enclosing
        // `.timeLimit(.minutes(1))` catches it.
        #expect(
            elapsed >= 2 && elapsed < 5,
            "expected timeout within 2–5s (got \(elapsed)s)"
        )
        // SIGTERM delivery and process reaping are asynchronous relative
        // to the continuation resume — under machine load `isRunning` can
        // lag the throw by a beat. Bounded poll: the contract is "the
        // pthread terminates the subprocess promptly," not "before the
        // timeout error surfaces."
        var terminated = false
        for _ in 0 ..< 40 {
            if !dummy.isRunning {
                terminated = true
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        #expect(
            terminated,
            "subprocess should be terminated by the pthread on timeout"
        )
    }
}

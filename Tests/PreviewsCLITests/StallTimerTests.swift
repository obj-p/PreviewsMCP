import Testing

@testable import PreviewsCLI

/// Unit tests for `StallTimer`. Wall-clock timing is used deliberately —
/// the timer's contract is "N seconds without a bump declares stall,"
/// and faking the clock here would only test the poll-interval math
/// rather than the observable behavior the `DaemonClient` relies on.
/// Thresholds are kept small (≤2s) to keep the suite fast.
@Suite("StallTimer")
struct StallTimerTests {

    @Test("waitForStall returns true when no bumps arrive within threshold")
    func stallsWithNoBumps() async {
        let timer = StallTimer()
        let start = ContinuousClock.now
        let stalled = await timer.waitForStall(threshold: .milliseconds(200))
        let elapsed = ContinuousClock.now - start

        #expect(stalled, "expected stall after 200ms of inactivity")
        #expect(
            elapsed >= .milliseconds(200),
            "waitForStall returned before threshold elapsed (got \(elapsed))")
        #expect(
            elapsed < .milliseconds(500),
            "waitForStall took much longer than threshold (got \(elapsed))")
    }

    @Test("bump() defers stall")
    func bumpDefersStall() async {
        let timer = StallTimer()
        let start = ContinuousClock.now

        // Spawn a Task that bumps at T+100ms, before the 200ms threshold
        // would otherwise trip. The timer should then wait until ~T+300ms
        // (last bump + threshold) before returning true.
        let bumper = Task {
            try? await Task.sleep(for: .milliseconds(100))
            await timer.bump()
        }

        let stalled = await timer.waitForStall(threshold: .milliseconds(200))
        await bumper.value
        let elapsed = ContinuousClock.now - start

        #expect(stalled)
        #expect(
            elapsed >= .milliseconds(300),
            "bump at +100ms should push stall to >=300ms (got \(elapsed))")
    }

    @Test("waitForStall returns false when containing Task is cancelled")
    func cancellationReturnsFalse() async {
        let timer = StallTimer()

        // Run the stall watcher in a detached child Task so we can
        // cancel it; local cancellation during `await` on the current
        // Task would throw, not return.
        let watcher = Task {
            await timer.waitForStall(threshold: .seconds(10))
        }

        // Cancel well before the 10s threshold.
        try? await Task.sleep(for: .milliseconds(50))
        watcher.cancel()

        let result = await watcher.value
        #expect(!result, "expected false on cancellation, got true")
    }
}

import Foundation
import PreviewsJITLink
import Testing

/// The agent's AppKit event-pump probe lives in its own swift_test target so it
/// runs alone. Its async event-dequeue poll needs the agent's run loop to be
/// scheduled within a budget; when it shared a binary with the other JITLink
/// suites, their concurrent JIT-agent spawns and fixture compiles starved that
/// run loop under CI load and the poll timed out (#262/#368 flake). bazel
/// `exclusive` keeps other test targets off the machine, and being the sole
/// test in this binary removes the in-process contention that `exclusive`
/// alone could not (Swift Testing parallelizes across suites within a binary).
struct EventPumpTests {
    @Test func agentDispatchesAppKitEvents() throws {
        let object = try FixtureSupport.compile("event_loop_probe.swift")
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: object.path)
        #expect(try session.runOnMain(symbol: "event_pump_install") == 1)
        // 10s budget: event dequeue lags behind runOnMain's main-queue blocks
        // on a loaded host (the mini's first CI run failed the old 2s budget
        // while the agent was still answering polls).
        var observed: Int32 = 0
        for _ in 0 ..< 100 where observed != 1 {
            Thread.sleep(forTimeInterval: 0.1)
            observed = try session.runOnMain(symbol: "event_pump_check")
        }

        // #391 timing-neutral diagnosis (does not touch the 10s verdict below).
        // The paradox: runOnMain answers every poll (the agent's main dispatch
        // queue drains) yet the posted .applicationDefined event is not
        // dispatched. Distinguish the possibilities from a single red:
        //   (A) idle window — stop polling so the agent's main run loop has no
        //       dispatch-main blocks to service; if the event fires now, it was
        //       merely starved behind our runOnMain polls (dispatch-source
        //       priority), not wedged.
        //   (B) extended poll — does it EVER fire (LAG, recoverable) or never
        //       (WEDGE, genuine run-loop mode/pump defect)?
        if observed != 1 {
            diag("RED at 10s budget; entering extended diagnosis")
            Thread.sleep(forTimeInterval: 5.0)
            let afterIdle = try session.runOnMain(symbol: "event_pump_check")
            let idleDelay = try session.runOnMain(symbol: "event_pump_fire_delay_ms")
            diag("after 5s idle (no polling): observed=\(afterIdle) fireDelayMs=\(idleDelay)")
            var late: Int32 = afterIdle
            for _ in 0 ..< 500 where late != 1 {
                Thread.sleep(forTimeInterval: 0.1)
                late = try session.runOnMain(symbol: "event_pump_check")
            }
            let finalDelay = try session.runOnMain(symbol: "event_pump_fire_delay_ms")
            diag("extended poll to ~60s: observed=\(late) fireDelayMs=\(finalDelay) "
                + "verdict=\(late == 1 ? (afterIdle == 1 ? "STARVED-BY-POLLING" : "LAG") : "WEDGE")")
        } else {
            let delay = try session.runOnMain(symbol: "event_pump_fire_delay_ms")
            diag("GREEN fireDelayMs=\(delay)")
        }

        #expect(observed == 1)
    }

    private func diag(_ message: String) {
        FileHandle.standardError.write(Data("EPT-DIAG: \(message)\n".utf8))
    }
}

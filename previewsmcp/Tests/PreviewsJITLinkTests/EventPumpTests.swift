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
        #expect(observed == 1)
    }
}

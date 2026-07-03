import os

/// Host-global CoreSimulator hygiene for the iOS-booting CLI suite.
///
/// In a full `bazel test //...` run this target executes after
/// `PreviewsIOSTests` and `IOSPreviewE2ETests` have driven simulators for
/// minutes. CoreSimulator is a host-global service, so by then its display
/// subsystem is degraded: SimulatorKit display-port attach slows to tens of
/// seconds and snapshot paths fall through to their slow bounded fallbacks,
/// stretching the suite's serialized chain past its timeout. It never
/// reproduces in isolation because nothing has degraded the service yet.
/// (Per-target copy, like `DaemonTestLock` — swift_test targets don't share
/// test sources, and the once-per-process guard is per-target by design.)
///
/// Reset that state ONCE per test process, before the first iOS preview boots:
/// shut every simulator down and bounce CoreSimulatorService so the next boot
/// starts from a clean service. Call while holding `DaemonTestLock` so the reset
/// never races a concurrent suite's simulator use.
enum CoreSimulatorHygiene {
    private static let didReset = OSAllocatedUnfairLock(initialState: false)

    /// Reset host-global CoreSimulator state once per process. Subsequent calls
    /// are no-ops. Best-effort: spawn failures are swallowed — the reset must
    /// not fail an otherwise-healthy test, and the next `simctl` call respawns
    /// the service regardless. Each command is bounded by `runExternal`'s
    /// timeout so a wedged `simctl` cannot park the suite's time limit.
    static func resetOnce() async {
        let shouldRun = didReset.withLock { done -> Bool in
            if done { return false }
            done = true
            return true
        }
        guard shouldRun else { return }

        // Shut down every booted simulator, then bounce the service. `killall`
        // is domain-agnostic (CoreSimulatorService runs in the GUI session, not
        // a fixed launchd domain) and the service auto-respawns on the next
        // simctl invocation — the daemon's session boot brings it back clean.
        _ = try? await CLIRunner.runExternal(
            "/usr/bin/xcrun", arguments: ["simctl", "shutdown", "all"]
        )
        _ = try? await CLIRunner.runExternal(
            "/usr/bin/killall",
            arguments: ["-9", "com.apple.CoreSimulator.CoreSimulatorService"]
        )
    }
}

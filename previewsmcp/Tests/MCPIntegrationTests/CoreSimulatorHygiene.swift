import Foundation
import os

/// Host-global CoreSimulator hygiene for the iOS e2e suites.
///
/// `MCPIntegrationTests` runs LAST in the Bazel graph, after `PreviewsIOSTests`
/// and `IOSPreviewE2ETests` have driven simulators for minutes. CoreSimulator is
/// a host-global service, so by the time these iOS MCP suites run its display
/// subsystem is degraded: SimulatorKit display-port attach slows to tens of
/// seconds, `waitForFirstFrame` times out, and `preview_snapshot` falls through
/// to the 33s one-shot fallback — which exceeds the test snapshot budget and
/// times out. That is the dominant full-suite-only flake; it never reproduces in
/// isolation because nothing has degraded the service yet.
///
/// Reset that state ONCE per test process, before the first iOS preview boots:
/// shut every simulator down and bounce CoreSimulatorService so the next boot
/// starts from a clean service. Call while holding `DaemonTestLock` so the reset
/// never races a concurrent suite's simulator use.
enum CoreSimulatorHygiene {
    private static let didReset = OSAllocatedUnfairLock(initialState: false)

    /// Reset host-global CoreSimulator state once per process. Subsequent calls
    /// are no-ops. Best-effort: a failed reset is logged, not thrown — it must
    /// not fail an otherwise-healthy test, and the next `simctl` call respawns
    /// the service regardless.
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
        // simctl invocation — pickUDID, moments later, brings it back clean.
        await run(["/usr/bin/xcrun", "simctl", "shutdown", "all"])
        await run(["/usr/bin/killall", "-9", "com.apple.CoreSimulator.CoreSimulatorService"])
    }

    private static func run(_ args: [String]) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: args[0])
                process.arguments = Array(args.dropFirst())
                process.standardOutput = FileHandle.nullDevice
                process.standardError = FileHandle.nullDevice
                do {
                    try process.run()
                    process.waitUntilExit()
                } catch {
                    print("CoreSimulatorHygiene: \(args.joined(separator: " ")) failed: \(error)")
                }
                continuation.resume()
            }
        }
    }
}

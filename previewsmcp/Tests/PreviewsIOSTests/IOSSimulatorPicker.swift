import Foundation
import PreviewsIOS

/// Helpers to eliminate cross-test simulator contention.
///
/// Previously three iOS test suites (`SimulatorManagerTests`,
/// `IOSPreviewSessionTests`, `IOSMCPTests`) all picked "first available"
/// or "first shutdown" from the same `xcrun simctl list` pool. With Swift
/// Testing running `@Suite`s in parallel, they boot the same device
/// concurrently and stomp on each other (see CI run 72576100973, where
/// two suites started at the exact same millisecond).
///
/// The right answer is NOT to serialize them behind a lock — CI has 132
/// simulators. The right answer is for each test to pick a DIFFERENT
/// device. This file provides the picker; each test passes a distinct
/// index. No coordination required; tests can again run in parallel.
enum IOSSimulatorPicker {

    /// Deterministic per-test device assignment. `index` must be unique
    /// per test function that needs an isolated simulator; the returned
    /// device is the `index`-th available iOS simulator in runtime-sorted
    /// order. Duplicated indices across tests would re-introduce the
    /// contention this picker exists to eliminate — declarative by
    /// design so reviewers notice duplicates.
    ///
    /// Current assignments (grep for `IOSSimulatorPicker.pick(index:` to audit):
    ///
    /// - index 0: `SimulatorManagerTests.bootAndShutdown`
    /// - index 1: `IOSPreviewSessionTests.endToEnd`
    /// - index 2: `IOSMCPTests.fullIOSWorkflow` (in MCP target; uses UDID
    ///   via preview_start's `deviceUDID` arg)
    /// - index 3: `IOSPreviewSessionTests.endToEndUIViewBodyKindProbe`
    ///
    /// Sort order matches the MCP-target sibling's
    /// `IOSSimulatorPicker.pickUDID(index:)` for consistency: iOS runtime
    /// names alphabetical, then device UDID within each runtime. Tests
    /// across both targets get the same device for the same index.
    static func pick(index: Int) async throws -> SimulatorManager.Device? {
        let manager = SimulatorManager()
        let devices = try await manager.listDevices()
        // Filter to iPhone-class devices only. iPad boots (particularly
        // iPad Air / Pro M2+) can exceed 60s on GHA CI runners, which
        // blows through our `simctl bootstatus` timeout; iPhones
        // typically boot in <15s. All three iOS tests are SwiftUI
        // previews that don't care which iPhone class they run on.
        let iPhones =
            devices
            .filter { d in
                let runtime = d.runtimeName ?? ""
                let name = d.name
                return d.isAvailable && runtime.contains("iOS") && name.contains("iPhone")
            }
            .sorted { a, b in
                let aRuntime = a.runtimeName ?? ""
                let bRuntime = b.runtimeName ?? ""
                if aRuntime != bRuntime { return aRuntime < bRuntime }
                return a.udid < b.udid
            }
        guard index < iPhones.count else { return nil }
        return iPhones[index]
    }
}

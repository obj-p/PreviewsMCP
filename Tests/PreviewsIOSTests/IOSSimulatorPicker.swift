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
    ///
    /// Sort order matches the MCP-target sibling's
    /// `IOSSimulatorPicker.pickUDID(index:)` for consistency: iOS runtime
    /// names alphabetical, then device UDID within each runtime. Tests
    /// across both targets get the same device for the same index.
    static func pick(index: Int) async throws -> SimulatorManager.Device? {
        let manager = SimulatorManager()
        let devices = try await manager.listDevices()
        let ios =
            devices
            .filter { $0.isAvailable && ($0.runtimeName ?? "").contains("iOS") }
            .sorted { a, b in
                let aRuntime = a.runtimeName ?? ""
                let bRuntime = b.runtimeName ?? ""
                if aRuntime != bRuntime { return aRuntime < bRuntime }
                return a.udid < b.udid
            }
        guard index < ios.count else { return nil }
        return ios[index]
    }
}

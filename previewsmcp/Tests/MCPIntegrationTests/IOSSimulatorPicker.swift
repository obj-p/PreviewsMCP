import Foundation
import PreviewsCore

/// Helpers to eliminate cross-test simulator contention (MCP target copy).
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
///
/// This copy lives in `MCPIntegrationTests` (whose only dependency is
/// `PreviewsCLI` + `MCP`, no `PreviewsIOS`), so it shells out to
/// `xcrun simctl list --json`. The sibling copy in `PreviewsIOSTests`
/// uses the in-process Swift API. Keep both in sync; the device
/// selection contract is what matters, not the enumeration path.
enum IOSSimulatorPicker {

    /// Deterministic per-test device UDID assignment. `index` must be
    /// unique per test function that needs an isolated simulator.
    ///
    /// Current assignments (grep for `IOSSimulatorPicker.pickUDID(index:` to audit):
    ///
    /// - index 0: `SimulatorManagerTests.bootAndShutdown`
    /// - index 1: `IOSPreviewSessionTests.endToEnd`
    /// - index 2: `IOSMCPTests.fullIOSWorkflow`
    static func pickUDID(index: Int) async throws -> String? {
        // Must drain stdout concurrently: `simctl list devices --json` on a
        // CI runner with 100+ simulators produces >64KB of JSON, filling
        // the OS pipe buffer. A naked `Process.run() + waitUntilExit()`
        // without reading the pipe deadlocks — simctl blocks on write,
        // waitUntilExit blocks forever. `runAsync` drains the pipe on a
        // background thread while the child runs (see AsyncProcess.swift).
        //
        // A 60s timeout bounds a truly hung simctl (observed on PR #141
        // CI); normal runs complete in <5s.
        let output: ProcessOutput
        do {
            output = try await runAsync(
                "/usr/bin/xcrun",
                arguments: ["simctl", "list", "devices", "available", "--json"],
                discardStderr: true,
                timeout: .seconds(60)
            )
        } catch {
            return nil
        }
        guard output.exitCode == 0 else { return nil }

        guard
            let data = output.stdout.data(using: .utf8),
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devicesByRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return nil }

        // Filter to iPhone-class devices only. iPad boots (particularly
        // iPad Air / Pro M2+) can exceed 60s on GHA CI runners, which
        // blows through our `simctl bootstatus` timeout; iPhones
        // typically boot in <15s. All three iOS tests are SwiftUI
        // previews that don't care which iPhone class they run on.
        //
        // Stable order: runtime alphabetical, UDID alphabetical within
        // each runtime. Matches the PreviewsIOSTests-target sibling so
        // tests across targets get the same device for the same index.
        var iPhoneUDIDs: [String] = []
        for runtime in devicesByRuntime.keys.sorted() where runtime.contains("iOS") {
            guard let list = devicesByRuntime[runtime] else { continue }
            let udids =
                list
                .filter { ($0["name"] as? String)?.contains("iPhone") == true }
                .compactMap { $0["udid"] as? String }
                .sorted()
            iPhoneUDIDs.append(contentsOf: udids)
        }
        guard index < iPhoneUDIDs.count else { return nil }
        return iPhoneUDIDs[index]
    }
}

import Foundation

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
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available", "--json"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devicesByRuntime = json["devices"] as? [String: [[String: Any]]]
        else { return nil }

        // Flatten iOS runtimes in a stable order: runtime alphabetical,
        // UDID alphabetical within each runtime. Matches the
        // PreviewsIOSTests-target sibling so tests across targets get the
        // same device for the same index.
        var iosUDIDs: [String] = []
        for runtime in devicesByRuntime.keys.sorted() where runtime.contains("iOS") {
            guard let list = devicesByRuntime[runtime] else { continue }
            let udids = list.compactMap { $0["udid"] as? String }.sorted()
            iosUDIDs.append(contentsOf: udids)
        }
        guard index < iosUDIDs.count else { return nil }
        return iosUDIDs[index]
    }
}

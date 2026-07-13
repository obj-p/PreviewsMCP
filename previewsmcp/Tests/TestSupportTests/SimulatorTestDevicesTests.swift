import Foundation
import PreviewsCore
import PreviewsTestSupport
import Testing

/// Touches the real CoreSimulator device set (its own `local`-tagged target,
/// separate from the hermetic `TestSupportTests`). Creating/listing devices
/// never boots one, so this stays cheap; the device it leaves behind IS the
/// intended end state (#337).
struct SimulatorTestDevicesTests {
    @Test(.timeLimit(.minutes(5)))
    func resolveIsIdempotentAndPinsTheShape() async throws {
        let simLock = try await SimulatorTestLock.acquire()
        defer { simLock.release() }

        guard let first = await SimulatorTestDevices.udid(index: 5) else {
            if let failure = SimulatorTestDevices.missingDeviceFailure(
                index: 5, isCI: SimulatorTestDevices.isCI
            ) {
                Issue.record("\(failure)")
            }
            print("Host cannot create \(SimulatorTestDevices.deviceType) — skipping")
            return
        }
        let second = await SimulatorTestDevices.udid(index: 5)
        #expect(second == first)

        let output = try await runAsync(
            "/usr/bin/xcrun",
            arguments: ["simctl", "list", "devices", "--json"],
            discardStderr: true,
            timeout: .seconds(60)
        )
        #expect(output.exitCode == 0)

        let data = output.stdout.data(using: .utf8) ?? Data()
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        let devicesByRuntime = json?["devices"] as? [String: [[String: Any]]] ?? [:]
        let entries = devicesByRuntime.values.joined()
            .filter { $0["name"] as? String == SimulatorTestDevices.name(index: 5) }
        #expect(entries.count == 1)
        #expect(entries.first?["udid"] as? String == first)
        #expect(
            entries.first?["deviceTypeIdentifier"] as? String == SimulatorTestDevices.deviceType
        )
    }
}

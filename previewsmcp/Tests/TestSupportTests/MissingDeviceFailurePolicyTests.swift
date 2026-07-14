import PreviewsTestSupport
import Testing

/// The guard that stands between a real CI provisioning failure and a silent
/// skip-as-green. The injected policy keeps this deterministic.
struct MissingDeviceFailurePolicyTests {
    @Test("under CI, a missing dedicated simulator fails rather than skips")
    func failsUnderCI() {
        do {
            _ = try SimulatorTestDevices.enforceAvailability(
                nil, index: 2, requiresDedicatedSim: true
            )
            Issue.record("missing required simulator should throw")
        } catch {
            #expect(error.localizedDescription.contains("index 2"))
            #expect(error.localizedDescription.contains("failing"))
        }
    }

    @Test("locally, a missing dedicated simulator skips (no failure recorded)")
    func skipsLocally() throws {
        let udid = try SimulatorTestDevices.enforceAvailability(
            nil, index: 2, requiresDedicatedSim: false
        )
        #expect(udid == nil)
    }

    @Test("an available simulator is preserved in either mode")
    func preservesAvailableDevice() throws {
        let udid = try SimulatorTestDevices.enforceAvailability(
            "TEST-UDID", index: 2, requiresDedicatedSim: true
        )
        #expect(udid == "TEST-UDID")
    }
}

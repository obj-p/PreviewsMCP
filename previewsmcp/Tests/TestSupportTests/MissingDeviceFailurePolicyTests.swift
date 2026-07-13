import PreviewsTestSupport
import Testing

/// The guard that stands between a real CI provisioning failure and a
/// silent skip-as-green. Deterministic (isCI injected) so it can't regress:
/// under CI a missing dedicated simulator must FAIL (yield a message the
/// caller records), and locally it must SKIP (yield nil).
struct MissingDeviceFailurePolicyTests {
    @Test("under CI, a missing dedicated simulator fails rather than skips")
    func failsUnderCI() {
        let failure = SimulatorTestDevices.missingDeviceFailure(index: 2, isCI: true)
        let message = try? #require(failure)
        #expect(message?.contains("index 2") == true)
        #expect(message?.contains("failing") == true)
    }

    @Test("locally, a missing dedicated simulator skips (no failure recorded)")
    func skipsLocally() {
        #expect(SimulatorTestDevices.missingDeviceFailure(index: 2, isCI: false) == nil)
    }
}

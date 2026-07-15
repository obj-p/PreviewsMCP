import Foundation
@testable import PreviewsEngine
import Testing

/// Contended-path coverage for the device-claim state machine
/// (docs/state-invalidation.md, L01). The races these pin: a start must
/// never tear down a session that is still launching, replacement is
/// ordered (stop completes before the new claim registers), and a claim
/// lost before confirmation reports itself.
@Suite("Device claims")
struct DeviceClaimsTests {
    private actor StopLog {
        private(set) var stopped: [String] = []
        func record(_ id: String) {
            stopped.append(id)
        }
    }

    @Test("free device claims without replacement")
    func freeDeviceClaims() async {
        let claims = DeviceClaims()
        let log = StopLog()
        let replaced = await claims.claim(device: "dev-1", owner: "a") { await log.record($0) }
        #expect(replaced == nil)
        #expect(await log.stopped.isEmpty)
        #expect(await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a"))
    }

    @Test("live incumbent is stopped and reported")
    func liveIncumbentReplaced() async {
        let claims = DeviceClaims()
        let log = StopLog()
        _ = await claims.claim(device: "dev-1", owner: "a") { await log.record($0) }
        _ = await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a")

        let replaced = await claims.claim(device: "dev-1", owner: "b") { await log.record($0) }
        #expect(replaced == "s-a")
        #expect(await log.stopped == ["s-a"])
        #expect(await claims.confirmLive(device: "dev-1", owner: "b", sessionID: "s-b"))
    }

    @Test("a claim mid-launch is waited out, never torn down")
    func claimingIncumbentIsWaitedOut() async throws {
        let claims = DeviceClaims()
        let log = StopLog()
        _ = await claims.claim(device: "dev-1", owner: "a") { await log.record($0) }

        let contender = Task {
            await claims.claim(device: "dev-1", owner: "b") { await log.record($0) }
        }
        // Give the contender time to reach the waiters queue; it must not
        // have replaced anything while the incumbent is still claiming.
        try await Task.sleep(for: .milliseconds(100))
        #expect(await log.stopped.isEmpty)

        _ = await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a")
        let replaced = await contender.value
        #expect(replaced == "s-a")
        #expect(await log.stopped == ["s-a"])
    }

    @Test("a released claim frees the device for waiters")
    func releasedClaimFreesDevice() async {
        let claims = DeviceClaims()
        let log = StopLog()
        _ = await claims.claim(device: "dev-1", owner: "a") { await log.record($0) }

        let contender = Task {
            await claims.claim(device: "dev-1", owner: "b") { await log.record($0) }
        }
        await claims.release(device: "dev-1", owner: "a")
        let replaced = await contender.value
        #expect(replaced == nil)
        #expect(await log.stopped.isEmpty)
    }

    @Test("confirm after release reports the lost claim")
    func confirmAfterReleaseFails() async {
        let claims = DeviceClaims()
        _ = await claims.claim(device: "dev-1", owner: "a") { _ in }
        await claims.release(device: "dev-1", owner: "a")
        #expect(await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a") == false)
    }

    @Test("releaseLive frees only the matching live session")
    func releaseLiveMatchesLiveSession() async {
        let claims = DeviceClaims()
        _ = await claims.claim(device: "dev-1", owner: "a") { _ in }
        await claims.releaseLive(device: "dev-1", sessionID: "s-a")
        #expect(await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a"),
                "a claiming reservation must not be released by session teardown")
        await claims.releaseLive(device: "dev-1", sessionID: "other")
        let stillHeld = await claims.claim(device: "dev-2", owner: "probe") { _ in }
        #expect(stillHeld == nil)
        await claims.releaseLive(device: "dev-1", sessionID: "s-a")
        let freed = await claims.claim(device: "dev-1", owner: "b") { _ in }
        #expect(freed == nil, "device should be free after releaseLive of the live session")
    }

    @Test("claims on different devices are independent")
    func devicesIndependent() async {
        let claims = DeviceClaims()
        let log = StopLog()
        _ = await claims.claim(device: "dev-1", owner: "a") { await log.record($0) }
        _ = await claims.confirmLive(device: "dev-1", owner: "a", sessionID: "s-a")
        let replaced = await claims.claim(device: "dev-2", owner: "b") { await log.record($0) }
        #expect(replaced == nil)
        #expect(await log.stopped.isEmpty)
    }
}

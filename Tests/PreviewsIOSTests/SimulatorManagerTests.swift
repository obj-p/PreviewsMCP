import Foundation
import Testing

@testable import PreviewsIOS

@Suite("SimulatorManager", .serialized)
struct SimulatorManagerTests {

    @Test("Load CoreSimulator and list devices")
    func listDevices() async throws {
        let manager = SimulatorManager()
        let devices = try await manager.listDevices()

        #expect(devices.count > 0, "Expected at least one simulator device")

        // Verify device properties are populated
        let first = devices[0]
        #expect(!first.name.isEmpty)
        #expect(!first.udid.isEmpty)
        #expect(!first.stateString.isEmpty)

        // Print for manual inspection
        print("Found \(devices.count) devices:")
        for d in devices.filter({ $0.isAvailable }).prefix(5) {
            print("  \(d)")
        }
    }

    @Test("List available runtimes")
    func listRuntimes() async throws {
        let manager = SimulatorManager()
        let runtimes = try await manager.listRuntimes()

        #expect(runtimes.count > 0, "Expected at least one runtime")

        print("Found \(runtimes.count) runtimes:")
        for rt in runtimes {
            print("  \(rt)")
        }
    }

    @Test("Find device by UDID")
    func findByUDID() async throws {
        let manager = SimulatorManager()
        let devices = try await manager.listDevices()
        let available = devices.filter { $0.isAvailable }
        guard let first = available.first else {
            print("No available devices to test findDevice")
            return
        }

        let found = try await manager.findDevice(udid: first.udid)
        #expect(found.udid == first.udid)
        #expect(found.name == first.name)
    }

    @Test("Find device with invalid UDID throws")
    func findInvalidUDID() async throws {
        let manager = SimulatorManager()
        await #expect(throws: SimulatorError.self) {
            try await manager.findDevice(udid: "00000000-0000-0000-0000-000000000000")
        }
    }

    @Test("Boot and shutdown a device")
    func bootAndShutdown() async throws {
        // Each test that boots a simulator gets its OWN device (distinct
        // IOSSimulatorPicker index) so the three iOS test suites don't
        // contend for the same device when Swift Testing runs them in
        // parallel. See IOSSimulatorPicker for the assignments.
        guard let target = try await IOSSimulatorPicker.pick(index: 0) else {
            print("No iOS simulator at picker index 0 — skipping")
            return
        }
        let manager = SimulatorManager()

        // Boot, test, then always shutdown — even if assertions fail.
        print("Booting \(target.name) (\(target.udid))...")
        try await manager.bootDevice(udid: target.udid)

        // Wrap test body so we always reach shutdown.
        var testError: (any Error)?
        do {
            let booted = try await manager.findDevice(udid: target.udid)
            // `bootDevice` blocks until the device is fully booted (via
            // `simctl bootstatus -b`), so the state must be `.booted` by
            // the time we get here — no more `.booting` tolerance.
            #expect(booted.state == SimulatorManager.DeviceState.booted)
            print("State after boot: \(booted.stateString)")

            // Take a screenshot (direct IOSurface capture with simctl fallback)
            let screenshotData = try await manager.screenshotData(udid: target.udid)
            #expect(screenshotData.count > 0)
            // Verify JPEG header (0xFF 0xD8) since default quality is < 1.0
            #expect(screenshotData[0] == 0xFF && screenshotData[1] == 0xD8)
            print("Screenshot captured: \(screenshotData.count) bytes (JPEG)")

            // Verify PNG output when quality >= 1.0
            let pngData = try await manager.screenshotData(udid: target.udid, jpegQuality: 1.0)
            #expect(pngData.count > 0)
            #expect(pngData[0] == 0x89 && pngData[1] == 0x50)  // PNG header
            print("PNG screenshot captured: \(pngData.count) bytes")
        } catch {
            testError = error
        }

        // Always shutdown.
        print("Shutting down...")
        try await manager.shutdownDevice(udid: target.udid)

        let afterShutdown = try await manager.findDevice(udid: target.udid)
        #expect(
            afterShutdown.state == SimulatorManager.DeviceState.shutdown
                || afterShutdown.state == SimulatorManager.DeviceState.shuttingDown
        )
        print("State after shutdown: \(afterShutdown.stateString)")

        if let testError { throw testError }
    }
}

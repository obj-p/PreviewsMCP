import Foundation
import Testing

@testable import PreviewsIOS

@Suite("SimulatorManager")
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
        let manager = SimulatorManager()
        let devices = try await manager.listDevices()
        guard
            let target = devices.first(where: {
                $0.isAvailable && $0.state == .shutdown
            })
        else {
            print("No available shutdown device to test boot/shutdown")
            return
        }

        // Boot, test, then always shutdown — even if assertions fail.
        print("Booting \(target.name) (\(target.udid))...")
        try await manager.bootDevice(udid: target.udid)

        // Wrap test body so we always reach shutdown.
        var testError: (any Error)?
        do {
            let booted = try await manager.findDevice(udid: target.udid)
            #expect(booted.state == .booted || booted.state == .booting)
            print("State after boot: \(booted.stateString)")

            // Take a screenshot (direct IOSurface capture with simctl fallback)
            try await Task.sleep(for: .seconds(5))
            let screenshotData = try await manager.screenshotData(udid: target.udid)
            #expect(screenshotData.count > 0)
            // Verify JPEG header (0xFF 0xD8) since default quality is < 1.0
            #expect(screenshotData[0] == 0xFF && screenshotData[1] == 0xD8)
            print("Screenshot captured: \(screenshotData.count) bytes (JPEG)")
        } catch {
            testError = error
        }

        // Always shutdown.
        print("Shutting down...")
        try await manager.shutdownDevice(udid: target.udid)

        let shutdown = try await manager.findDevice(udid: target.udid)
        #expect(shutdown.state == .shutdown || shutdown.state == .shuttingDown)
        print("State after shutdown: \(shutdown.stateString)")

        if let testError { throw testError }
    }
}

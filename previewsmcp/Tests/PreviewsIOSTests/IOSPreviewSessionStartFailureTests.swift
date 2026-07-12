import Foundation
import PreviewsCore
@testable import PreviewsIOS
import PreviewsTestSupport
@preconcurrency import SimulatorBridge
import Testing

/// Guards the #391 leak-on-FAILURE symmetry: a `start()` that throws AFTER booting the device
/// must reclaim what it created — shut down the device WE booted and release the host
/// sockets/JIT listener — exactly like a clean `stop()`. The host-fd half of that was missing
/// until review, and a review-caught leak with no regression guard silently regresses.
///
/// Drives the real production `start()` with a stub `SimulatorControlling` whose `installApp`
/// throws right after the boot branch. Off-runner: no sim boots (stub), one attempt
/// (`maxBootAttempts: 1`, so no 3s inter-attempt sleeps). The agent build + loopback sockets
/// are real but cheap; the JIT reloader is never reached (install fails first).
@Suite("IOSPreviewSession start() failure reclaim")
struct IOSPreviewSessionStartFailureTests {
    @Test(.enabled(if: IOSAgentBuilder.jitOrcRuntimePath != nil))
    func failedStartShutsDownDeviceItBootedAndReleasesHostFDs() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-start-fail-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let source = dir.appendingPathComponent("V.swift")
        try "import SwiftUI\n#Preview { Text(\"hi\") }\n"
            .write(to: source, atomically: true, encoding: .utf8)

        let stub = StubSimulatorControl(deviceState: .shutdown)
        let session = try await IOSPreviewSession(
            sourceFile: source,
            deviceUDID: "STUB-UDID-0001",
            compiler: Compiler(platform: .iOS),
            agentBuilder: IOSAgentBuilder(),
            simulatorManager: stub,
            maxBootAttempts: 1,
            makeJITReloader: { _, _ in
                fatalError("JIT reloader must not be reached: install fails before the JIT step")
            }
        )

        await #expect(throws: (any Error).self) {
            _ = try await session.start()
        }

        // The device state was .shutdown, so the session booted it (didBootDevice = true) — the
        // failure path must therefore shut it back down, and only that device.
        #expect(await stub.bootDeviceCalls == 1)
        #expect(await stub.shutdownBestEffortUDIDs == ["STUB-UDID-0001"])
        // Host resources released: the JIT listener fd, bound before the install throw, is closed.
        #expect(await session.jitListenFDForTesting == -1)
    }
}

/// Boots succeed; `installApp` throws just after the boot branch. The methods reached only
/// after a successful install (`launchApp`, HID/framebuffer, screenshot) `fatalError` — they
/// require a real booted sim / private-API objects and never fire on this failure path.
private actor StubSimulatorControl: SimulatorControlling {
    private let deviceState: SimulatorManager.DeviceState
    private(set) var bootDeviceCalls = 0
    private(set) var shutdownBestEffortUDIDs: [String] = []

    init(deviceState: SimulatorManager.DeviceState) {
        self.deviceState = deviceState
    }

    func findDevice(udid: String) async throws -> SimulatorManager.Device {
        SimulatorManager.Device(
            name: "stub", udid: udid, state: deviceState, stateString: "Shutdown",
            runtimeName: "iOS 26.2", runtimeIdentifier: nil, deviceTypeName: "iPhone 17",
            isAvailable: true
        )
    }

    func bootDevice(udid _: String, timeout _: Duration) async throws {
        bootDeviceCalls += 1
    }

    func installApp(udid _: String, appPath _: String) async throws {
        throw StubError.installFailedPostBoot
    }

    func terminateAppIfRunning(udid _: String, bundleID _: String) async {}
    func shutdownDevice(udid _: String) async throws {}
    func shutdownDeviceBestEffort(udid: String) async {
        shutdownBestEffortUDIDs.append(udid)
    }

    func quitSimulatorApp() async {}

    func launchApp(
        udid _: String, bundleID _: String, arguments _: [String], environment _: [String: String]
    ) async throws -> Int {
        fatalError("unreached on the install-failure path")
    }

    func launchAppInBackground(
        udid _: String, bundleID _: String, arguments _: [String]
    ) async throws -> Int {
        fatalError("unreached on the install-failure path")
    }

    func makeHIDClient(udid _: String) async throws -> SBHIDClient {
        fatalError("unreached on the install-failure path")
    }

    func makeFramebufferStreamer(
        udid _: String, jpegQuality _: Double
    ) async throws -> SBFramebufferStreamer {
        fatalError("unreached on the install-failure path")
    }

    func screenshotData(udid _: String, jpegQuality _: Double) async throws -> Data {
        fatalError("unreached on the install-failure path")
    }
}

private enum StubError: Error { case installFailedPostBoot }

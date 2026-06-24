import Testing

@testable import PreviewsIOS

/// The pre-iOS-26 gate (#282) keys off `SimulatorManager.Device.iosMajorVersion`
/// and `isPreviewSupported`, parsed from the runtime identifier or name.
@Suite("iOS runtime gate")
struct IOSRuntimeGateTests {
    private func device(identifier: String?, name: String?) -> SimulatorManager.Device {
        SimulatorManager.Device(
            name: "iPhone 16",
            udid: "00000000-0000-0000-0000-000000000000",
            state: .shutdown,
            stateString: "Shutdown",
            runtimeName: name,
            runtimeIdentifier: identifier,
            deviceTypeName: "iPhone 16",
            isAvailable: true)
    }

    @Test("parses major from the runtime identifier")
    func parsesFromIdentifier() {
        let d = device(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", name: nil)
        #expect(d.iosMajorVersion == 18)
    }

    @Test("parses major from the runtime name when the identifier is absent")
    func parsesFromName() {
        let d = device(identifier: nil, name: "iOS 26.2")
        #expect(d.iosMajorVersion == 26)
    }

    @Test("nil when neither yields an iOS version")
    func nilWhenUnknown() {
        let d = device(identifier: "com.apple.CoreSimulator.SimRuntime.watchOS-11-0", name: "watchOS 11.0")
        #expect(d.iosMajorVersion == nil)
    }

    @Test("26 is supported, 25 is not, unknown is allowed through")
    func previewSupport() {
        #expect(device(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-26-0", name: nil).isPreviewSupported)
        #expect(!device(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-25-9", name: nil).isPreviewSupported)
        #expect(!device(identifier: "com.apple.CoreSimulator.SimRuntime.iOS-18-6", name: nil).isPreviewSupported)
        #expect(device(identifier: nil, name: nil).isPreviewSupported)
    }
}

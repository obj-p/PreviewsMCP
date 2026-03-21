import Foundation
import PreviewsCore
import SimulatorBridge

/// Manages iOS simulator devices via CoreSimulator.framework (loaded at runtime).
public actor SimulatorManager {

    /// Sendable snapshot of a simulator device.
    public struct Device: Sendable, CustomStringConvertible {
        public let name: String
        public let udid: String
        public let state: DeviceState
        public let stateString: String
        public let runtimeName: String?
        public let runtimeIdentifier: String?
        public let deviceTypeName: String?
        public let isAvailable: Bool

        public var description: String {
            "\(name) (\(udid)) \(stateString) — \(runtimeName ?? "no runtime")"
        }
    }

    public enum DeviceState: Int, Sendable {
        case creating = 0
        case shutdown = 1
        case booting = 2
        case booted = 3
        case shuttingDown = 4
    }

    /// Sendable snapshot of a simulator runtime.
    public struct Runtime: Sendable, CustomStringConvertible {
        public let name: String
        public let identifier: String
        public let versionString: String
        public let isAvailable: Bool

        public var description: String {
            "\(name) (\(versionString)) \(isAvailable ? "available" : "unavailable")"
        }
    }

    private var loaded = false

    public init() {}

    // MARK: - Framework Loading

    private func ensureLoaded() throws {
        guard !loaded else { return }
        var error: NSError?
        guard SBLoadFramework(&error) else {
            throw SimulatorError.frameworkLoadFailed(error?.localizedDescription ?? "unknown error")
        }
        loaded = true
    }

    // MARK: - Device Enumeration

    /// List all available simulator devices.
    public func listDevices() throws -> [Device] {
        try ensureLoaded()
        var error: NSError?
        guard let sbDevices = SBListDevices(&error) else {
            throw SimulatorError.listFailed(error?.localizedDescription ?? "unknown error")
        }
        return sbDevices.map { device(from: $0) }
    }

    /// List available runtimes.
    public func listRuntimes() throws -> [Runtime] {
        try ensureLoaded()
        var error: NSError?
        guard let sbRuntimes = SBListRuntimes(&error) else {
            throw SimulatorError.listFailed(error?.localizedDescription ?? "unknown error")
        }
        return sbRuntimes.map { runtime(from: $0) }
    }

    /// Find a device by UDID.
    public func findDevice(udid: String) throws -> Device {
        try ensureLoaded()
        var error: NSError?
        guard let sbDevice = SBFindDeviceByUDID(udid, &error) else {
            throw SimulatorError.deviceNotFound(error?.localizedDescription ?? "device not found: \(udid)")
        }
        return device(from: sbDevice)
    }

    /// Find the first booted device.
    public func findBootedDevice() throws -> Device {
        try ensureLoaded()
        var error: NSError?
        guard let sbDevice = SBFindBootedDevice(&error) else {
            throw SimulatorError.deviceNotFound(error?.localizedDescription ?? "no booted device")
        }
        return device(from: sbDevice)
    }

    // MARK: - Device Operations

    /// Boot a simulator device.
    public func bootDevice(udid: String) throws {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        do {
            try sbDevice.boot()
        } catch {
            throw SimulatorError.bootFailed(error.localizedDescription)
        }
    }

    /// Shutdown a simulator device.
    public func shutdownDevice(udid: String) throws {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        do {
            try sbDevice.shutdown()
        } catch {
            throw SimulatorError.shutdownFailed(error.localizedDescription)
        }
    }

    /// Install an app bundle on a booted device.
    public func installApp(udid: String, appPath: String) throws {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        do {
            try sbDevice.installApp(at: appPath)
        } catch {
            throw SimulatorError.installFailed(error.localizedDescription)
        }
    }

    /// Launch an app on a booted device. Returns the PID.
    public func launchApp(
        udid: String,
        bundleID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) throws -> Int {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        var launchError: NSError?
        let pid = sbDevice.launchApp(
            withBundleID: bundleID,
            arguments: arguments,
            environment: environment,
            error: &launchError
        )
        guard pid >= 0 else {
            throw SimulatorError.launchFailed(launchError?.localizedDescription ?? "unknown error")
        }
        return Int(pid)
    }

    // MARK: - Screenshots

    /// Capture a screenshot using direct IOSurface access.
    /// Falls back to simctl if IOSurface is unavailable.
    /// - Parameters:
    ///   - udid: Device UDID.
    ///   - jpegQuality: JPEG quality 0.0–1.0. Values >= 1.0 produce PNG. Default: 0.85.
    /// - Returns: Image data (JPEG or PNG).
    public func screenshotData(udid: String, jpegQuality: Double = 0.85) async throws -> Data {
        let sbDevice = try findSBDevice(udid: udid)

        // Try direct framebuffer capture first
        var fbError: NSError?
        if let data = SBCaptureFramebuffer(sbDevice, jpegQuality, &fbError) {
            return data as Data
        }

        // Fall back to simctl subprocess
        fputs(
            "SimulatorBridge: IOSurface capture failed (\(fbError?.localizedDescription ?? "unknown")), falling back to simctl\n",
            stderr)
        let imageType = jpegQuality >= 1.0 ? "png" : "jpeg"
        return try await screenshotDataViaSimctl(udid: udid, imageType: imageType)
    }

    /// Capture a screenshot via simctl and return image data (fallback path).
    private func screenshotDataViaSimctl(udid: String, imageType: String = "png") async throws -> Data {
        let ext = imageType == "jpeg" ? "jpg" : imageType
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_screenshot_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempPath) }
        let result = try await runAsync(
            "/usr/bin/xcrun",
            arguments: ["simctl", "io", udid, "screenshot", "--type=\(imageType)", tempPath.path]
        )
        if result.exitCode != 0 {
            throw SimulatorError.screenshotFailed("simctl screenshot failed: \(result.stderr)")
        }
        return try Data(contentsOf: tempPath)
    }

    // MARK: - Private

    private func findSBDevice(udid: String) throws -> SBDevice {
        var error: NSError?
        guard let sbDevice = SBFindDeviceByUDID(udid, &error) else {
            throw SimulatorError.deviceNotFound(error?.localizedDescription ?? udid)
        }
        return sbDevice
    }

    private func device(from sb: SBDevice) -> Device {
        Device(
            name: sb.name,
            udid: sb.udid.uuidString,
            state: DeviceState(rawValue: sb.state.rawValue) ?? .shutdown,
            stateString: sb.stateString,
            runtimeName: sb.runtimeName,
            runtimeIdentifier: sb.runtimeIdentifier,
            deviceTypeName: sb.deviceTypeName,
            isAvailable: sb.isAvailable
        )
    }

    private func runtime(from sb: SBRuntime) -> Runtime {
        Runtime(
            name: sb.name,
            identifier: sb.identifier,
            versionString: sb.versionString,
            isAvailable: sb.isAvailable
        )
    }
}

// MARK: - Errors

public enum SimulatorError: Error, LocalizedError, CustomStringConvertible {
    case frameworkLoadFailed(String)
    case listFailed(String)
    case deviceNotFound(String)
    case bootFailed(String)
    case shutdownFailed(String)
    case installFailed(String)
    case launchFailed(String)
    case screenshotFailed(String)

    public var description: String {
        switch self {
        case .frameworkLoadFailed(let msg): return "Failed to load CoreSimulator: \(msg)"
        case .listFailed(let msg): return "Failed to list devices: \(msg)"
        case .deviceNotFound(let msg): return "Device not found: \(msg)"
        case .bootFailed(let msg): return "Boot failed: \(msg)"
        case .shutdownFailed(let msg): return "Shutdown failed: \(msg)"
        case .installFailed(let msg): return "Install failed: \(msg)"
        case .launchFailed(let msg): return "Launch failed: \(msg)"
        case .screenshotFailed(let msg): return "Screenshot failed: \(msg)"
        }
    }

    public var errorDescription: String? { description }
}

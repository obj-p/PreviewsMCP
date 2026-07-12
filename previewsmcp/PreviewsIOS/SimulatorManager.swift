import Foundation
import os
import PreviewsCore
@preconcurrency import SimulatorBridge

/// Resolves the available iOS simulator devices. Kept as a protocol so
/// `simulator_list`'s formatting/DTO-mapping logic can be tested against a
/// deterministic in-memory device list without loading CoreSimulator.
public protocol SimulatorLister: Sendable {
    func listDevices() async throws -> [SimulatorManager.Device]
}

/// The simulator operations `IOSPreviewSession` drives, extracted as a seam so tests can
/// inject a stub — `SimulatorManager` is a private-API-backed actor that boots real devices,
/// so a session's boot/install/launch/teardown path is otherwise only reachable via the
/// real-simulator E2E gate. All requirements are `async` so `SimulatorManager`'s actor-
/// isolated (and synchronous) methods witness them.
public protocol SimulatorControlling: Sendable {
    func findDevice(udid: String) async throws -> SimulatorManager.Device
    func bootDevice(udid: String, timeout: Duration) async throws
    func installApp(udid: String, appPath: String) async throws
    func launchApp(
        udid: String, bundleID: String, arguments: [String], environment: [String: String]
    ) async throws -> Int
    func launchAppInBackground(udid: String, bundleID: String, arguments: [String]) async throws -> Int
    func terminateAppIfRunning(udid: String, bundleID: String) async
    func shutdownDevice(udid: String) async throws
    func shutdownDeviceBestEffort(udid: String) async
    func quitSimulatorApp() async
    func makeHIDClient(udid: String) async throws -> SBHIDClient
    func makeFramebufferStreamer(udid: String, jpegQuality: Double) async throws -> SBFramebufferStreamer
    func screenshotData(udid: String, jpegQuality: Double) async throws -> Data
}

public extension SimulatorControlling {
    /// Default-argument conveniences matching `SimulatorManager`'s own defaults, so call
    /// sites keep working through `any SimulatorControlling` (a protocol can't carry defaults).
    func bootDevice(udid: String) async throws {
        try await bootDevice(udid: udid, timeout: .seconds(600))
    }

    func launchApp(udid: String, bundleID: String, arguments: [String]) async throws -> Int {
        try await launchApp(udid: udid, bundleID: bundleID, arguments: arguments, environment: [:])
    }

    func makeFramebufferStreamer(udid: String) async throws -> SBFramebufferStreamer {
        try await makeFramebufferStreamer(udid: udid, jpegQuality: 0.7)
    }
}

/// Manages iOS simulator devices via CoreSimulator.framework (loaded at runtime).
public actor SimulatorManager: SimulatorLister, SimulatorControlling {
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

        public init(
            name: String,
            udid: String,
            state: DeviceState,
            stateString: String,
            runtimeName: String?,
            runtimeIdentifier: String?,
            deviceTypeName: String?,
            isAvailable: Bool
        ) {
            self.name = name
            self.udid = udid
            self.state = state
            self.stateString = stateString
            self.runtimeName = runtimeName
            self.runtimeIdentifier = runtimeIdentifier
            self.deviceTypeName = deviceTypeName
            self.isAvailable = isAvailable
        }

        public var description: String {
            "\(name) (\(udid)) \(stateString) — \(runtimeName ?? "no runtime")"
        }

        /// Live previews need the iOS 26+ scene-hosting API (#282).
        public static let minimumSupportedIOSMajorVersion = 26

        /// The major iOS version of this device's runtime, parsed from the runtime
        /// identifier (`...SimRuntime.iOS-26-2`) or name (`iOS 26.2`). Nil for a
        /// non-iOS or unparseable runtime.
        public var iosMajorVersion: Int? {
            if let id = runtimeIdentifier, let range = id.range(of: "SimRuntime.iOS-"),
               let value = Int(id[range.upperBound...].prefix { $0 != "-" })
            {
                return value
            }
            if let name = runtimeName, let range = name.range(of: "iOS "),
               let value = Int(name[range.upperBound...].prefix { $0.isNumber })
            {
                return value
            }
            return nil
        }

        /// Whether this device can host a live preview. A known pre-26 runtime
        /// cannot (#282); an unparseable runtime is allowed through to the gate.
        public var isPreviewSupported: Bool {
            (iosMajorVersion ?? Self.minimumSupportedIOSMajorVersion)
                >= Self.minimumSupportedIOSMajorVersion
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

    /// Create a daemon-side HID input client bound to a device. Injects events
    /// at the simulator digitizer, independent of the in-app host touch path.
    public func makeHIDClient(udid: String) throws -> SBHIDClient {
        try ensureLoaded()
        var error: NSError?
        guard let sbDevice = SBFindDeviceByUDID(udid, &error) else {
            throw SimulatorError.deviceNotFound(error?.localizedDescription ?? "device not found: \(udid)")
        }
        guard let client = SBCreateHIDClient(sbDevice, &error) else {
            throw SimulatorError.hidClientFailed(error?.localizedDescription ?? "unknown")
        }
        return client
    }

    /// Create a daemon-side event-driven framebuffer streamer bound to a device.
    /// Registers screen callbacks to keep the display pipeline wired to us and
    /// caches the latest frame as it changes — the hot-loop counterpart to the
    /// one-shot `screenshotData`.
    public func makeFramebufferStreamer(
        udid: String, jpegQuality: Double = 0.7
    ) throws -> SBFramebufferStreamer {
        try ensureLoaded()
        var error: NSError?
        guard let sbDevice = SBFindDeviceByUDID(udid, &error) else {
            throw SimulatorError.deviceNotFound(error?.localizedDescription ?? "device not found: \(udid)")
        }
        guard let streamer = SBCreateFramebufferStreamer(sbDevice, jpegQuality, &error) else {
            throw SimulatorError.screenshotFailed(error?.localizedDescription ?? "unknown")
        }
        return streamer
    }

    // MARK: - Device Operations

    /// Boot a simulator device and block until it's fully booted (SpringBoard
    /// ready, IOSurface available).
    ///
    /// `SBDevice.boot()` alone returns as soon as boot *starts* — state is
    /// often `.booting` or even briefly `.booted`-but-display-not-ready for
    /// a few seconds after. Callers that screenshot immediately race that
    /// window; on slow CI runners the race loses, `SBCaptureFramebuffer`
    /// reports "No IOSurface found on any display port," and the simctl
    /// fallback itself blocks on the same pending display (see
    /// `screenshotDataViaSimctl`).
    ///
    /// After initiating boot, delegate to `xcrun simctl bootstatus -b`,
    /// Apple's documented primitive that blocks "until the device finishes
    /// booting" — including SpringBoard launch. On timeout, we surface
    /// simctl's own captured stdout/stderr in the error so a reader can
    /// tell *which* stage of boot stalled (`Waiting on <SpringBoard>` vs.
    /// `Data Migration` vs. silent hang).
    ///
    /// Default timeout is 600s. Typical CI boots complete in 5–15s, but
    /// observed P99 on combined-load GHA macos-15 runners (build +
    /// multi-test + warm-sim concurrently) has exceeded 180s while the
    /// simulator was genuinely still making progress — subsequent retries
    /// saw the device already booted. 600s keeps a dead-hung boot bounded
    /// without flaking healthy-but-slow boots.
    public func bootDevice(udid: String, timeout: Duration = .seconds(600)) async throws {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        do {
            try sbDevice.boot()
        } catch {
            throw SimulatorError.bootFailed(error.localizedDescription)
        }

        do {
            _ = try await runAsync(
                "/usr/bin/xcrun",
                arguments: ["simctl", "bootstatus", udid, "-b"],
                timeout: timeout
            )
        } catch let t as AsyncProcessTimeout {
            throw SimulatorError.bootFailed(
                "simctl bootstatus did not complete within \(t.duration) for \(udid). "
                    + "simctl stdout: \(t.capturedStdout.isEmpty ? "(empty)" : t.capturedStdout). "
                    + "simctl stderr: \(t.capturedStderr.isEmpty ? "(empty)" : t.capturedStderr)"
            )
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

    /// Run a blocking SB private-API call on a GCD thread, racing a
    /// wall-clock deadline. Exactly one resume wins. If the deadline does,
    /// the blocked thread is abandoned (the call cannot be cancelled — it
    /// eventually unblocks or leaks with the process) and `onTimeout` is
    /// returned.
    private static func runBlockingWithDeadline<T: Sendable>(
        timeout: TimeInterval,
        onTimeout: T,
        _ body: @escaping @Sendable () -> T
    ) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let queue = DispatchQueue.global(qos: .userInitiated)
            let finish: @Sendable (T) -> Void = { value in
                let first = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                if first { cont.resume(returning: value) }
            }
            queue.async { finish(body()) }
            queue.asyncAfter(deadline: .now() + timeout) { finish(onTimeout) }
        }
    }

    /// Launch an app WITHOUT activating it, via CoreSimulator's
    /// `activate_suspended` launch option: the process runs its launch
    /// sequence but FrontBoard never brings it to the foreground (#352).
    ///
    /// `simctl launch` has no equivalent flag, so this one launch path uses
    /// the SBDevice private API that `launchApp` retired on PR #141 (it can
    /// hang unboundably on an intermediate-booted device). The call runs
    /// under `runBlockingWithDeadline` with a 60s bound: on timeout this
    /// throws and callers recover the device through their reboot-retry
    /// loop, same as a hung `simctl launch`.
    public func launchAppInBackground(
        udid: String, bundleID: String, arguments: [String]
    ) async throws -> Int {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        let result: Result<Int, SimulatorError> = await Self.runBlockingWithDeadline(
            timeout: 60,
            onTimeout: .failure(
                .launchFailed("background launch of \(bundleID) hung (exceeded 60s)")
            )
        ) {
            var error: NSError?
            let pid = sbDevice.launchApp(
                withBundleID: bundleID,
                arguments: arguments,
                environment: nil,
                suspended: true,
                error: &error
            )
            guard pid > 0 else {
                return .failure(
                    .launchFailed(
                        error?.localizedDescription ?? "background launch failed for \(bundleID)"
                    )
                )
            }
            return .success(pid)
        }
        return try result.get()
    }

    /// Best-effort terminate of `bundleID` on `udid` via `simctl terminate`.
    ///
    /// Defensive cleanup before re-launching the host: a prior test or
    /// retry can leave the same bundle running on the simulator, and a
    /// fresh launch on top of it has been observed to wedge the
    /// simulator backend on PR #141 CI. simctl terminate is a no-op
    /// when the app isn't running.
    ///
    /// - Non-fatal: returns normally on non-zero exit (app was not
    ///   running) or on timeout (simctl itself wedged).
    /// - 30s timeout bounds any genuine simctl hang; the normal path
    ///   completes in <1s.
    public func terminateAppIfRunning(udid: String, bundleID: String) async {
        _ = try? await runAsync(
            "/usr/bin/xcrun",
            arguments: ["simctl", "terminate", udid, bundleID],
            discardStderr: true,
            timeout: .seconds(30)
        )
    }

    /// Shut down a device via `simctl shutdown`, best-effort and time-bounded. Used by
    /// session teardown to reclaim a device this process booted (#391). Prefers simctl over
    /// the SB private-API `shutdownDevice(_:)` because the latter is unbounded and can block
    /// on a wedged CoreSimulatorService — the very degraded state we are cleaning up after —
    /// whereas simctl runs as a subprocess bounded by runAsync's SIGTERM→SIGKILL timeout.
    /// A no-op (harmless nonzero exit) when the device is already shut down.
    public func shutdownDeviceBestEffort(udid: String) async {
        _ = try? await runAsync(
            "/usr/bin/xcrun",
            arguments: ["simctl", "shutdown", udid],
            discardStderr: true,
            timeout: .seconds(30)
        )
    }

    /// Quit the Simulator.app GUI (opened for non-headless sessions), best-effort and
    /// time-bounded. A no-op when it isn't running. Quitting the GUI does not shut down the
    /// CoreSimulator devices it displays — those are reclaimed separately via
    /// `shutdownDeviceBestEffort`.
    public func quitSimulatorApp() async {
        _ = try? await runAsync(
            "/usr/bin/osascript",
            arguments: ["-e", "tell application \"Simulator\" to quit"],
            discardStderr: true,
            timeout: .seconds(10)
        )
    }

    /// Launch an app on a booted device. Returns the PID.
    ///
    /// Uses `xcrun simctl launch` instead of the SBDevice private API.
    /// The private-API path (`SBDevice.launchApp`) has been observed
    /// on PR #141 CI to hang indefinitely when the simulator is in an
    /// intermediate-booted state; even a wall-clock-bounded wrapper
    /// around it leaves the blocked thread orphaned and doesn't
    /// actually succeed. simctl launch runs as a subprocess we can
    /// properly bound with SIGTERM → SIGKILL via runAsync's timeout
    /// infrastructure, and fails fast with a diagnostic stderr from
    /// simctl instead of wedging.
    ///
    /// Args are passed after the bundle ID. Environment vars are
    /// forwarded via SIMCTL_CHILD_ prefixes per simctl(1). Stdout
    /// of the successful case is `<bundleID>: <pid>` which we parse.
    public func launchApp(
        udid: String,
        bundleID: String,
        arguments: [String] = [],
        environment: [String: String] = [:]
    ) async throws -> Int {
        // simctl forwards any env vars prefixed with SIMCTL_CHILD_ to
        // the launched app with the prefix stripped. Our callers pass
        // a small dictionary (usually empty); we pre-set them in the
        // current process env before running simctl, then restore.
        for (k, v) in environment {
            setenv("SIMCTL_CHILD_\(k)", v, 1)
        }
        defer {
            for k in environment.keys {
                unsetenv("SIMCTL_CHILD_\(k)")
            }
        }

        let args = ["simctl", "launch", udid, bundleID] + arguments
        let output: ProcessOutput
        do {
            output = try await runAsync(
                "/usr/bin/xcrun",
                arguments: args,
                timeout: .seconds(60)
            )
        } catch let timeout as AsyncProcessTimeout {
            throw SimulatorError.launchFailed(
                "simctl launch hung (exceeded \(timeout.duration)); "
                    + "stderr: \(timeout.capturedStderr.isEmpty ? "(empty)" : timeout.capturedStderr)"
            )
        }
        guard output.exitCode == 0 else {
            throw SimulatorError.launchFailed(
                "simctl launch failed (exit \(output.exitCode)): \(output.stderr)"
            )
        }
        // Output format: `<bundleID>: <pid>\n`
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidPart = trimmed.split(separator: ":").last,
              let pid = Int(pidPart.trimmingCharacters(in: .whitespaces))
        else {
            throw SimulatorError.launchFailed(
                "simctl launch returned unexpected stdout: \(trimmed.debugDescription)"
            )
        }
        return pid
    }

    /// Spawn a program inside the device's boot session, the way `simctl spawn`
    /// does, with no `xcrun` subprocess. An in-session spawn shares the host
    /// loopback network, so the child can connect back to a TCP listener on the
    /// host — a bare `SimDevice spawnWithPath:` does not. Returns the PID.
    ///
    /// `onExit`, if given, is invoked on a background queue with the child's
    /// exit status when it terminates.
    public func spawnInSession(
        udid: String,
        program: String,
        arguments: [String] = [],
        environment: [String: String] = [:],
        onExit: (@Sendable (Int32) -> Void)? = nil
    ) throws -> Int {
        try ensureLoaded()
        let sbDevice = try findSBDevice(udid: udid)
        var error: NSError?
        let pid = sbDevice.spawnInSession(
            withPath: program,
            arguments: arguments,
            environment: environment,
            terminationHandler: onExit.map { cb in { status in cb(status) } },
            error: &error
        )
        guard pid >= 0 else {
            throw SimulatorError.launchFailed(
                error?.localizedDescription ?? "spawnInSession failed for \(program)"
            )
        }
        return pid
    }

    // MARK: - Screenshots

    /// Capture a screenshot using direct IOSurface access.
    /// Falls back to simctl if IOSurface is unavailable.
    /// - Parameters:
    ///   - udid: Device UDID.
    ///   - jpegQuality: JPEG quality 0.0–1.0. Values >= 1.0 produce PNG. Default: 0.85.
    /// - Returns: Image data (JPEG or PNG).
    ///
    /// Implementation note: display attach is asynchronous vs. the
    /// `simctl bootstatus`-reported "boot complete" state. On CI runners,
    /// `SBCaptureFramebuffer` can report "No IOSurface found on any
    /// display port" for several seconds after SpringBoard is up —
    /// display subsystem is still wiring ports. We retry direct capture
    /// up to `iosurfaceRetryCount` times with a short backoff before
    /// conceding to the simctl fallback (which itself needs a display
    /// and can hang if one never attaches). Observed on GHA runners:
    /// display typically attaches within 2–8s after bootstatus returns.
    public func screenshotData(udid: String, jpegQuality: Double = 0.85) async throws -> Data {
        let sbDevice = try findSBDevice(udid: udid)

        // Retry direct IOSurface capture — absorbs the display-attach race.
        //
        // Each attempt is bounded by a wall-clock timeout because
        // `SBCaptureFramebuffer` is a synchronous private-API C call that
        // can block indefinitely inside the kernel on a display that
        // never attaches — observed on PR #141 CI. Swift concurrency
        // cancellation can't preempt a sync C call, so we race it
        // against a Dispatch-based deadline and abandon the blocked
        // thread if it doesn't return (the thread leaks but the async
        // task unblocks and we fall through to simctl).
        let iosurfaceRetryCount = 5
        let iosurfaceBackoff = Duration.seconds(2)
        let iosurfacePerAttemptTimeout: TimeInterval = 5
        var lastFBError: NSError?
        for attempt in 1 ... iosurfaceRetryCount {
            let result = await captureFramebufferWithTimeout(
                sbDevice: sbDevice,
                jpegQuality: jpegQuality,
                timeout: iosurfacePerAttemptTimeout
            )
            switch result {
            case let .success(data):
                if attempt > 1 {
                    Log.info(
                        "SimulatorBridge: IOSurface capture succeeded on attempt \(attempt)/\(iosurfaceRetryCount)"
                    )
                }
                return data
            case let .failure(err):
                lastFBError = err
            case .timedOut:
                Log.warn(
                    "SimulatorBridge: IOSurface capture attempt \(attempt)/\(iosurfaceRetryCount) hung, abandoning"
                )
            }
            if attempt < iosurfaceRetryCount {
                try? await Task.sleep(for: iosurfaceBackoff)
            }
        }

        // Fall back to simctl subprocess (itself bounded by a timeout — see
        // screenshotDataViaSimctl — so a display that never attaches fails
        // fast with actionable context instead of hanging indefinitely).
        Log.warn(
            "SimulatorBridge: IOSurface capture failed after \(iosurfaceRetryCount) attempts (\(lastFBError?.localizedDescription ?? "unknown/timed-out")), falling back to simctl"
        )
        let imageType = jpegQuality >= 1.0 ? "png" : "jpeg"
        return try await screenshotDataViaSimctl(udid: udid, imageType: imageType)
    }

    /// Wall-clock-bounded wrapper around `SBCaptureFramebuffer`.
    ///
    /// `SBCaptureFramebuffer` is a synchronous private-API C function that
    /// on PR #141 CI has been observed to block indefinitely inside the
    /// kernel when the simulator's display subsystem is in a bad state.
    /// Swift `Task` cancellation can't preempt a synchronous C call, so it
    /// runs under `runBlockingWithDeadline`; a deadline win reports
    /// `.timedOut` so the caller can retry or fall back to the simctl path.
    private enum FramebufferCaptureResult {
        case success(Data)
        case failure(NSError?)
        case timedOut
    }

    private func captureFramebufferWithTimeout(
        sbDevice: SBDevice,
        jpegQuality: Double,
        timeout: TimeInterval
    ) async -> FramebufferCaptureResult {
        await Self.runBlockingWithDeadline(timeout: timeout, onTimeout: .timedOut) {
            var err: NSError?
            guard let data = SBCaptureFramebuffer(sbDevice, jpegQuality, &err) else {
                return .failure(err)
            }
            return .success(data as Data)
        }
    }

    /// Capture a screenshot via simctl and return image data (fallback path).
    ///
    /// Bounded by a 60s timeout. `simctl io screenshot` can hang indefinitely
    /// when the simulator has no display attached (e.g., headless boots on
    /// CI runners where `SBCaptureFramebuffer` already failed with
    /// "No IOSurface found on any display port"). Without a bound, the
    /// caller hits its outer `.timeLimit` after 10 minutes with no
    /// actionable signal.
    ///
    /// 180s chosen empirically: local completes in <1s; prior green
    /// CI showed ~30s worst case; on PR #141 CI the MCP workflow saw
    /// simctl hang >60s and surface
    /// `simctl io screenshot hung (exceeded 60.0 seconds); likely a
    /// simulator with no attached display`. The sibling PreviewsIOSTests
    /// E2E on the same runner completed simctl screenshot in ~22s, so
    /// this isn't a dead hang — the display just attaches slowly under
    /// load. 180s absorbs that variance while still bounded well below
    /// the enclosing 20-minute `.timeLimit`.
    private func screenshotDataViaSimctl(udid: String, imageType: String = "png") async throws -> Data {
        let ext = imageType == "jpeg" ? "jpg" : imageType
        let tempPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("sim_screenshot_\(UUID().uuidString).\(ext)")
        defer { try? FileManager.default.removeItem(at: tempPath) }
        let result: ProcessOutput
        do {
            result = try await runAsync(
                "/usr/bin/xcrun",
                arguments: [
                    "simctl", "io", udid, "screenshot",
                    "--type=\(imageType)", tempPath.path,
                ],
                timeout: .seconds(180)
            )
        } catch let timeout as AsyncProcessTimeout {
            throw SimulatorError.screenshotFailed(
                "simctl io screenshot hung (exceeded \(timeout.duration)); "
                    + "likely a simulator with no attached display "
                    + "(see IOSurface fallback above)"
            )
        }
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
    case hidClientFailed(String)

    public var description: String {
        switch self {
        case let .frameworkLoadFailed(msg): "Failed to load CoreSimulator: \(msg)"
        case let .listFailed(msg): "Failed to list devices: \(msg)"
        case let .deviceNotFound(msg): "Device not found: \(msg)"
        case let .bootFailed(msg): "Boot failed: \(msg)"
        case let .shutdownFailed(msg): "Shutdown failed: \(msg)"
        case let .installFailed(msg): "Install failed: \(msg)"
        case let .launchFailed(msg): "Launch failed: \(msg)"
        case let .screenshotFailed(msg): "Screenshot failed: \(msg)"
        case let .hidClientFailed(msg): "HID client creation failed: \(msg)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

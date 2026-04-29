import Foundation
import PreviewsCore
import SimulatorBridge
import os

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
                "simctl launch failed (exit \(output.exitCode)): \(output.stderr)")
        }
        // Output format: `<bundleID>: <pid>\n`
        let trimmed = output.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pidPart = trimmed.split(separator: ":").last,
            let pid = Int(pidPart.trimmingCharacters(in: .whitespaces))
        else {
            throw SimulatorError.launchFailed(
                "simctl launch returned unexpected stdout: \(trimmed.debugDescription)")
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
        for attempt in 1...iosurfaceRetryCount {
            let result = await captureFramebufferWithTimeout(
                sbDevice: sbDevice,
                jpegQuality: jpegQuality,
                timeout: iosurfacePerAttemptTimeout)
            switch result {
            case .success(let data):
                if attempt > 1 {
                    fputs(
                        "SimulatorBridge: IOSurface capture succeeded on attempt \(attempt)/\(iosurfaceRetryCount)\n",
                        stderr)
                }
                return data
            case .failure(let err):
                lastFBError = err
            case .timedOut:
                fputs(
                    "SimulatorBridge: IOSurface capture attempt \(attempt)/\(iosurfaceRetryCount) hung, abandoning\n",
                    stderr)
            }
            if attempt < iosurfaceRetryCount {
                try? await Task.sleep(for: iosurfaceBackoff)
            }
        }

        // Fall back to simctl subprocess (itself bounded by a timeout — see
        // screenshotDataViaSimctl — so a display that never attaches fails
        // fast with actionable context instead of hanging indefinitely).
        fputs(
            "SimulatorBridge: IOSurface capture failed after \(iosurfaceRetryCount) attempts (\(lastFBError?.localizedDescription ?? "unknown/timed-out")), falling back to simctl\n",
            stderr)
        let imageType = jpegQuality >= 1.0 ? "png" : "jpeg"
        return try await screenshotDataViaSimctl(udid: udid, imageType: imageType)
    }

    /// Wall-clock-bounded wrapper around `SBCaptureFramebuffer`.
    ///
    /// `SBCaptureFramebuffer` is a synchronous private-API C function that
    /// on PR #141 CI has been observed to block indefinitely inside the
    /// kernel when the simulator's display subsystem is in a bad state.
    /// Swift `Task` cancellation can't preempt a synchronous C call, so
    /// we dispatch the call onto a background thread and race it against
    /// a semaphore-based deadline. If the deadline wins, we abandon the
    /// blocked thread (it will eventually unblock or leak with the
    /// process) and report `.timedOut` so the caller can retry or fall
    /// back to the simctl path.
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
        await withCheckedContinuation { (cont: CheckedContinuation<FramebufferCaptureResult, Never>) in
            let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
            let queue = DispatchQueue.global(qos: .userInitiated)

            queue.async {
                var err: NSError?
                let data = SBCaptureFramebuffer(sbDevice, jpegQuality, &err)
                let didResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard didResume else { return }
                if let data {
                    cont.resume(returning: .success(data as Data))
                } else {
                    cont.resume(returning: .failure(err))
                }
            }

            queue.asyncAfter(deadline: .now() + timeout) {
                let didResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard didResume else { return }
                cont.resume(returning: .timedOut)
            }
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

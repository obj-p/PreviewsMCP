import Foundation
import Virtualization

/// Owns the `VZVirtualMachine` instance and its lifecycle.
///
/// `VMHost` is `@MainActor` because `VZVirtualMachine` requires its
/// methods to be called on the queue the instance was created with — we
/// always create on main, so all of `VMHost` lives on main. Callers from
/// other contexts hop via `await`.
@MainActor
public final class VMHost {
    public let bundle: VMBundle
    public let machine: VZVirtualMachine

    public init(bundle: VMBundle) throws {
        self.bundle = bundle
        let config = try VMConfiguration.build(bundle: bundle)
        self.machine = VZVirtualMachine(configuration: config)
    }

    public var state: VZVirtualMachine.State { machine.state }

    public func start() async throws {
        Log.info("starting VM (bundle=\(bundle.url.lastPathComponent), cpu=\(bundle.config.cpuCount), mem=\(bundle.config.memorySizeBytes / 1024 / 1024)MiB)")
        do {
            try await machine.start()
        } catch {
            throw VMError("VZVirtualMachine.start failed", underlying: error)
        }
        Log.info("VM state = \(machine.state.description)")
    }

    public func waitForIP(timeout: TimeInterval = 120) async throws -> String {
        Log.info("waiting for DHCP lease on MAC \(bundle.config.macAddress) (timeout=\(Int(timeout))s)")
        let ip = try await VMNetwork.waitForIP(
            mac: bundle.config.macAddress, timeout: timeout)
        Log.info("guest IP = \(ip)")
        return ip
    }

    /// Request graceful shutdown (sends an ACPI shutdown request; the guest
    /// has to cooperate). Returns immediately; pair with `waitForStop`.
    public func requestStop() throws {
        Log.info("requesting graceful guest shutdown")
        do {
            try machine.requestStop()
        } catch {
            throw VMError("VZVirtualMachine.requestStop failed", underlying: error)
        }
    }

    /// Force-stop without guest cooperation. Use as a fallback if
    /// `requestStop` + `waitForStop` doesn't reach `.stopped` in time.
    public func forceStop() async throws {
        Log.info("force-stopping VM")
        do {
            try await machine.stop()
        } catch {
            throw VMError("VZVirtualMachine.stop failed", underlying: error)
        }
    }

    /// Block until the VM reaches `.stopped`. Polls because the delegate
    /// callback path is harder to plumb cleanly through async/await without
    /// adding more state — and for our use case (research CLI) a few-second
    /// poll cadence is fine.
    public func waitForStop(timeout: TimeInterval = 60) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while machine.state != .stopped && Date() < deadline {
            Log.debug("waiting for stop, state=\(machine.state.description)")
            try await Task.sleep(for: .milliseconds(500))
        }
        if machine.state != .stopped {
            throw VMError(
                "VM did not reach .stopped within \(Int(timeout))s; state=\(machine.state.description)"
            )
        }
    }
}

extension VZVirtualMachine.State {
    public var description: String {
        switch self {
        case .stopped: return "stopped"
        case .running: return "running"
        case .paused: return "paused"
        case .error: return "error"
        case .starting: return "starting"
        case .pausing: return "pausing"
        case .resuming: return "resuming"
        case .stopping: return "stopping"
        case .saving: return "saving"
        case .restoring: return "restoring"
        @unknown default: return "unknown(\(rawValue))"
        }
    }
}

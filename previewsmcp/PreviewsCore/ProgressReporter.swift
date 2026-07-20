/// Progress reporting for long-running preview operations.
public enum BuildPhase: String, Sendable {
    case detectingProject
    case buildingProject
    case compilingBridge
    case compilingAgentApp
    case bootingSimulator
    case installingApp
    case launchingApp
    case connectingToApp
    case runningSetup
    case rendering
    case capturingSnapshot

    /// The phase name as it reads in a failure line:
    /// "<userLabel> failed: <message>".
    public var userLabel: String {
        switch self {
        case .detectingProject: "Detecting the project"
        case .buildingProject: "Building the project"
        case .compilingBridge: "Compiling the preview"
        case .compilingAgentApp: "Compiling the agent app"
        case .bootingSimulator: "Booting the simulator"
        case .installingApp: "Installing the app"
        case .launchingApp: "Launching the app"
        case .connectingToApp: "Connecting to the app"
        case .runningSetup: "Running the preview setup"
        case .rendering: "Rendering the preview"
        case .capturingSnapshot: "Capturing the snapshot"
        }
    }
}

/// A receiver for build/launch progress updates.
///
/// Implementations must be `Sendable`. The ``report(_:message:)`` method
/// is called at each phase boundary in the build/boot/launch pipeline;
/// ``tick(message:elapsed:)`` re-emits the current step with an elapsed
/// marker while a phase is still running and must not advance any step
/// counter (docs/phase-error-protocol.md, the phase clock).
public protocol ProgressReporter: Sendable {
    func report(_ phase: BuildPhase, message: String) async
    func tick(message: String, elapsed: Duration) async
}

public extension ProgressReporter {
    /// Report the phase boundary, then run `work` with a heartbeat: after
    /// `interval`, and every `interval` thereafter, `tick` re-emits the
    /// message with the elapsed time. The ticker runs detached so a work
    /// body that pins its own executor cannot starve it; it is cancelled
    /// when the work returns or throws, and the throw propagates
    /// untouched — classification is the catch sites' job, not the
    /// clock's.
    func phase<T: Sendable>(
        _ phase: BuildPhase, _ message: String,
        interval: Duration = .seconds(5),
        work: @Sendable () async throws -> T
    ) async rethrows -> T {
        await report(phase, message: message)
        let start = ContinuousClock.now
        let ticker = Task.detached {
            while true {
                try await Task.sleep(for: interval)
                await self.tick(message: message, elapsed: ContinuousClock.now - start)
            }
        }
        do {
            let value = try await work()
            ticker.cancel()
            _ = await ticker.result
            return value
        } catch {
            ticker.cancel()
            _ = await ticker.result
            throw error
        }
    }
}

/// A nil reporter runs the work bare: no boundary line, no ticker —
/// watcher-triggered refreshes pass nil and stay free of clock
/// machinery.
public func withPhase<T: Sendable>(
    _ reporter: (any ProgressReporter)?, _ phase: BuildPhase, _ message: String,
    work: @Sendable () async throws -> T
) async rethrows -> T {
    guard let reporter else { return try await work() }
    return try await reporter.phase(phase, message, work: work)
}

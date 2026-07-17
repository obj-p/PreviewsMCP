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
        case .capturingSnapshot: "Capturing the snapshot"
        }
    }
}

/// A receiver for build/launch progress updates.
///
/// Implementations must be `Sendable`. The ``report(_:message:)`` method
/// is called at each phase boundary in the build/boot/launch pipeline.
public protocol ProgressReporter: Sendable {
    func report(_ phase: BuildPhase, message: String) async
}

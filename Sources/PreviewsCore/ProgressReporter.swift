/// Progress reporting for long-running preview operations.
public enum BuildPhase: String, Sendable {
    case detectingProject
    case buildingProject
    case compilingBridge
    case compilingHostApp
    case bootingSimulator
    case installingApp
    case launchingApp
    case connectingToApp
    case capturingSnapshot
}

/// A receiver for build/launch progress updates.
///
/// Implementations must be `Sendable`. The ``report(_:message:)`` method
/// is called at each phase boundary in the build/boot/launch pipeline.
public protocol ProgressReporter: Sendable {
    func report(_ phase: BuildPhase, message: String) async
}

import Foundation

/// A source of JPEG frames for the app interface stream. The app interface taps
/// the shell-composite display surface; concrete sources map that onto a
/// backend.
public protocol FrameSource: Sendable {
    func nextFrame() async -> Data?
}

/// Captures the simulator display (the shell composite) as JPEG via the
/// direct-IOSurface path. A first cut: it re-captures per frame with no
/// seed-skip and reuses the retrying `screenshotData`; event-driven capture and
/// change detection are later optimizations.
public struct SimulatorFrameSource: FrameSource {
    private let manager: SimulatorManager
    private let udid: String
    private let jpegQuality: Double

    public init(manager: SimulatorManager, udid: String, jpegQuality: Double = 0.7) {
        self.manager = manager
        self.udid = udid
        self.jpegQuality = jpegQuality
    }

    public func nextFrame() async -> Data? {
        try? await manager.screenshotData(udid: udid, jpegQuality: jpegQuality)
    }
}

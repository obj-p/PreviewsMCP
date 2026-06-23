import Foundation

@preconcurrency import SimulatorBridge

/// A source of JPEG frames for the app interface stream. The app interface taps
/// the shell-composite display surface; concrete sources map that onto a
/// backend.
public protocol FrameSource: Sendable {
    func nextFrame() async -> Data?
}

/// Captures the simulator display (the shell composite) as JPEG via an
/// event-driven `SBFramebufferStreamer`. The streamer holds the display
/// pipeline open and re-encodes only when the IOSurface seed changes, caching
/// the latest frame; `nextFrame` just returns that cache, so a stalled display
/// never blocks the pull loop the way the retrying `screenshotData` did.
public final class EventDrivenFrameSource: FrameSource, @unchecked Sendable {
    private let streamer: SBFramebufferStreamer

    public init(streamer: SBFramebufferStreamer) {
        self.streamer = streamer
    }

    public func nextFrame() async -> Data? {
        streamer.latestFrame()
    }

    public func stop() {
        streamer.stop()
    }
}

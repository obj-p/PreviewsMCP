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
    private let captureQueue = DispatchQueue(label: "com.previewsmcp.frame-capture", qos: .userInitiated)

    public init(streamer: SBFramebufferStreamer) {
        self.streamer = streamer
    }

    public func nextFrame() async -> Data? {
        streamer.latestFrame()
    }

    /// How many frames the event-driven pipeline has accepted and how stale
    /// the newest one is. Logged with each cached-frame snapshot so a frozen
    /// specimen shows whether the display pipeline stalled (#368).
    public func frameStats() -> (count: UInt64, ageSeconds: Double) {
        var count: UInt64 = 0
        var age: Double = 0
        streamer.getFrameCount(&count, ageSeconds: &age)
        return (count, age)
    }

    /// Capture the live display surface on demand at `jpegQuality` (PNG when
    /// `jpegQuality >= 1.0`), reusing the streamer's wired pipeline. Unlike
    /// `nextFrame`, this re-encodes current content at the requested quality
    /// rather than returning the cached stream JPEG. Nil if no surface is wired.
    ///
    /// `captureFrame(atQuality:)` blocks on the streamer's capture queue, so run
    /// it off the caller's executor: a caller on an actor must not have its
    /// executor thread parked while the private framebuffer framework works.
    public func captureFresh(jpegQuality: Double) async -> Data? {
        await withCheckedContinuation { continuation in
            captureQueue.async {
                continuation.resume(returning: self.streamer.captureFrame(atQuality: jpegQuality))
            }
        }
    }

    /// Block until the streamer has captured at least one frame, proving the
    /// SimulatorKit display pipeline is wired. Creating the streamer registers
    /// the screen callbacks that wire the pipeline, and its heal timer re-wires
    /// once per second until the first frame lands — so a freshly started
    /// streamer that races display attach under load recovers here instead of
    /// the caller's first one-shot capture failing with "No IOSurface."
    /// Returns true once a frame is available, false if none arrives in `timeout`.
    public func waitForFirstFrame(timeout: Duration) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if streamer.latestFrame() != nil {
                return true
            }
            do {
                try await Task.sleep(for: .milliseconds(200))
            } catch {
                return false
            }
        }
        return false
    }

    public func stop() {
        streamer.stop()
    }
}

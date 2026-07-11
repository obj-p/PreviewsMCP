import Foundation
import PreviewsCore
@preconcurrency import SimulatorBridge

/// A destination for normalized (0..1) pointer input on a preview surface. The
/// app interface speaks normalized coordinates; concrete sinks map them onto a
/// backend. This is independent of the in-app host-app touch path used by
/// `preview_touch`.
public protocol InputSink: Sendable {
    func tap(x: Double, y: Double)
    func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, steps: Int)
}

/// Drives input at the simulator digitizer through a daemon-side HID client.
public struct IndigoHIDInputSink: InputSink {
    private let client: SBHIDClient

    public init(client: SBHIDClient) {
        self.client = client
    }

    public func tap(x: Double, y: Double) {
        if !client.tapAt(x: x, y: y) {
            Log.warn("hid: tap not dispatched (Indigo mouse function unavailable)")
        }
    }

    public func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, steps: Int) {
        if !client.dragFrom(x: fromX, fromY: fromY, toX: toX, toY: toY, steps: steps) {
            Log.warn("hid: drag not dispatched (Indigo mouse function unavailable)")
        }
    }
}

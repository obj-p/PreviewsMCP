import Foundation
@testable import PreviewsCore
import Testing

@Suite("PreviewSession frame sidecar")
struct PreviewSessionFrameSidecarTests {
    @Test("frame sidecar path is stable for a session id")
    func pathIsStableForID() {
        let a = PreviewSession.frameSidecarPath(for: "abc")
        let b = PreviewSession.frameSidecarPath(for: "abc")
        #expect(a == b)
        #expect(a.lastPathComponent.contains("abc"))
    }

    @Test("stored window frame is nil when no sidecar exists")
    func nilWhenAbsent() {
        #expect(PreviewSession.storedWindowFrame(for: "no-such-session-\(UUID().uuidString)") == nil)
    }

    @Test("stored window frame round-trips a written sidecar")
    func roundTrips() throws {
        let id = "frame-test-\(UUID().uuidString)"
        let url = PreviewSession.frameSidecarPath(for: id)
        let dict: [String: Any] = ["x": 12, "y": 34, "width": 567, "height": 890, "key": false]
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = PreviewSession.storedWindowFrame(for: id)
        #expect(frame?.x == 12)
        #expect(frame?.y == 34)
        #expect(frame?.width == 567)
        #expect(frame?.height == 890)
        #expect(frame?.isKey == false)
    }

    @Test("stored window frame without key state defaults to key")
    func missingKeyDefaultsToKey() throws {
        let id = "frame-test-\(UUID().uuidString)"
        let url = PreviewSession.frameSidecarPath(for: id)
        let dict: [String: Double] = ["x": 12, "y": 34, "width": 567, "height": 890]
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        #expect(PreviewSession.storedWindowFrame(for: id)?.isKey == true)
    }

    @Test("recording key state overwrites key and keeps the recorded frame")
    func recordKeyStateKeepsFrame() throws {
        let id = "frame-test-\(UUID().uuidString)"
        let url = PreviewSession.frameSidecarPath(for: id)
        let dict: [String: Any] = ["x": 12, "y": 34, "width": 567, "height": 890, "key": false]
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        PreviewSession.recordWindowKeyState(true, for: id)
        let frame = PreviewSession.storedWindowFrame(for: id)
        #expect(frame?.isKey == true)
        #expect(frame?.x == 12)
        #expect(frame?.height == 890)
    }

    @Test("recording key state without a sidecar records nothing")
    func recordKeyStateWithoutSidecarIsNoop() {
        let id = "frame-test-\(UUID().uuidString)"
        PreviewSession.recordWindowKeyState(true, for: id)
        #expect(PreviewSession.storedWindowFrame(for: id) == nil)
    }
}

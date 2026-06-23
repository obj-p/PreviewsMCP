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
        let dict: [String: Double] = ["x": 12, "y": 34, "width": 567, "height": 890]
        try JSONSerialization.data(withJSONObject: dict).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }

        let frame = PreviewSession.storedWindowFrame(for: id)
        #expect(frame?.x == 12)
        #expect(frame?.y == 34)
        #expect(frame?.width == 567)
        #expect(frame?.height == 890)
    }
}

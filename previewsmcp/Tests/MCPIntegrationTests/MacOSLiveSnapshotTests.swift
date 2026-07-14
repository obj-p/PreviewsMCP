import AppKit
import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// #346: `preview_snapshot` on a VISIBLE macOS window must reflect the live
/// window's current state, not the PNG written at the last render. The
/// `LiveSnapshotProbe` fixture flips blue→red ~0.4s after appearing with no
/// source edit — a post-render state change the render-time PNG cannot contain.
///
/// The visible session must snapshot red (live). The headless session must
/// stay blue (render-time PNG untouched — the gate the coordinator flagged).
@Suite("MCP macOS live snapshot", .serialized)
struct MacOSLiveSnapshotTests {
    static let probePath: String =
        MCPTestServer.spmExampleRoot.appendingPathComponent("Sources/ToDo/LiveSnapshotProbe.swift").path

    /// Dominant color of the image's center pixel: `.red`, `.blue`, or `.other`.
    enum CenterColor { case red, blue, other }

    static func centerColor(of content: [Tool.Content]) throws -> CenterColor {
        let (data, _) = try MCPTestServer.extractImageData(from: content)
        guard let rep = NSBitmapImageRep(data: data),
              let c = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
              .usingColorSpace(.deviceRGB)
        else { return .other }
        let r = c.redComponent, b = c.blueComponent
        if r > b + 0.3 { return .red }
        if b > r + 0.3 { return .blue }
        return .other
    }

    @Test("visible window snapshot reflects live post-render state", .timeLimit(.minutes(20)))
    func visibleSnapshotIsLive() async throws {
        let lock = try await DaemonTestLock.acquire()
        defer { lock.release() }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(Self.probePath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
                "headless": .bool(false),
            ]
        )
        #expect(startError != true, "preview_start (visible) should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)
        defer {
            Task { _ = try? await server.callTool(
                name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
            ) }
        }

        // The render-time PNG captured the pre-flip blue. Poll live snapshots
        // until the flip (0.4s) lands and the live window reads red — generous
        // cap so a slow agent delays the pass rather than failing it.
        var last = CenterColor.other
        for _ in 0 ..< 40 {
            let (snap, snapError) = try await server.callTool(
                name: "preview_snapshot",
                arguments: ["sessionID": .string(sessionID), "quality": .double(1.0)]
            )
            #expect(snapError != true, "snapshot should succeed")
            last = try Self.centerColor(of: snap)
            if last == .red { break }
            try await Task.sleep(for: .milliseconds(250))
        }
        #expect(last == .red, "visible snapshot must reflect the live red state, got \(last)")
    }

    @Test("headless snapshot keeps the render-time PNG (gate untouched)", .timeLimit(.minutes(20)))
    func headlessSnapshotStaysRenderTime() async throws {
        let lock = try await DaemonTestLock.acquire()
        defer { lock.release() }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(Self.probePath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
                "headless": .bool(true),
            ]
        )
        #expect(startError != true, "preview_start (headless) should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)
        defer {
            Task { _ = try? await server.callTool(
                name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
            ) }
        }

        // Wait well past the fixture's 0.4s flip. A headless session never
        // re-rasters live, so its snapshot stays the render-time blue no matter
        // what the off-screen window's state advanced to.
        try await Task.sleep(for: .seconds(2))
        let (snap, snapError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID), "quality": .double(1.0)]
        )
        #expect(snapError != true, "snapshot should succeed")
        let color = try Self.centerColor(of: snap)
        #expect(color == .blue, "headless snapshot must stay the render-time blue, got \(color)")
    }
}

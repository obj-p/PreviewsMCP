import Foundation
import MCP
import PreviewsIOS
@preconcurrency import SimulatorBridge
import Testing

/// Verifies the per-session app interface (PreviewAppServer): normalized pointer
/// input POSTed to its loopback `/control` endpoint drives the hosted agent
/// scene through the IndigoHID sink. Separate from the agent MCP/CLI path.
@Suite("iOS app server control", .serialized)
struct IOSAppServerTests {

    @Test(
        "POST /control drives the preview via IndigoHID",
        .timeLimit(.minutes(20)),
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "boots a simulator + compiles a preview; local-only like fullIOSWorkflow"
        ))
    func controlDrivesPreview() async throws {
        guard let deviceUDID = try await IOSSimulatorPicker.pickUDID(index: 3) else {
            print("No iOS simulator at picker index 3 — skipping")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
                "deviceUDID": .string(deviceUDID),
                "headless": .bool(true),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        #expect(startError != true, "iOS preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)
        try await Task.sleep(for: .seconds(3))

        // Stand up the app interface over loopback, backed by the IndigoHID sink.
        let appServer = PreviewAppServer(
            sink: IndigoHIDInputSink(client: try await SimulatorManager().makeHIDClient(udid: deviceUDID))
        )
        let port = try await appServer.start()
        defer { appServer.stop() }

        // Drag over the control channel to scroll the list. A vertical drag over
        // the list changes the framebuffer on any device, proving the POST drove
        // the hosted scene through the IndigoHID sink. (Tap-on-a-control is
        // device-position-sensitive and is covered at the sink in
        // IOSHIDInputTests; tap and drag share this same /control pipe.)
        let beforeDrag = try await server.snapshotBytes(sessionID: sessionID)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "control POST should return 200")

        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeDrag, timeout: .seconds(10))

        _ = try await server.callTool(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)])
    }
}

/// Verifies the PreviewAppServer MJPEG plumbing with a stub frame source. No
/// simulator: cross-process display capture is owned by the daemon in
/// production, and the real IOSurface capture is covered by preview_snapshot.
@Suite("PreviewAppServer stream")
struct PreviewAppServerStreamTests {

    private struct StubFrameSource: FrameSource {
        let jpeg: Data
        func nextFrame() async -> Data? { jpeg }
    }

    private struct NoopInputSink: InputSink {
        func tap(x: Double, y: Double) {}
        func drag(fromX: Double, fromY: Double, toX: Double, toY: Double, steps: Int) {}
    }

    @Test("GET /stream.mjpeg serves multipart JPEG frames")
    func streamServesFrames() async throws {
        let jpeg = Data([0xFF, 0xD8, 0xFF, 0x01, 0x02, 0x03, 0xFF, 0xD9])
        let appServer = PreviewAppServer(
            sink: NoopInputSink(),
            frameSource: StubFrameSource(jpeg: jpeg),
            streamIntervalMS: 10
        )
        let port = try await appServer.start()
        defer { appServer.stop() }

        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream.mjpeg")!)
        request.timeoutInterval = 10
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
        #expect(contentType.contains("multipart/x-mixed-replace"), "stream should be MJPEG multipart")

        // URLSession unwraps multipart/x-mixed-replace, delivering the part
        // bodies without the boundary, so assert on the JPEG payload itself.
        var buffer = Data()
        for try await byte in bytes {
            buffer.append(byte)
            if buffer.count >= 256 { break }
        }
        #expect(buffer.range(of: jpeg) != nil, "stream should carry the source JPEG bytes")
    }
}

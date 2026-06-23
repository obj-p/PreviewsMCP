import Foundation
import MCP
import PreviewsIOS
import Testing

/// Verifies the per-session app interface that the daemon hosts in-process:
/// `preview_start` returns its loopback port, `POST /control` drives the hosted
/// scene through IndigoHID, and `GET /stream.mjpeg` streams the shell composite.
/// Separate from the agent MCP/CLI path.
@Suite("iOS app server", .serialized)
struct IOSAppServerTests {

    private struct StartInfo: Decodable {
        let appServerPort: Int?
    }

    @Test(
        "daemon-hosted app server drives and streams the preview",
        .timeLimit(.minutes(20)),
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "boots a simulator + compiles a preview; local-only like fullIOSWorkflow"
        ))
    func appServerEndToEnd() async throws {
        guard let deviceUDID = try await IOSSimulatorPicker.pickUDID(index: 3) else {
            print("No iOS simulator at picker index 3 — skipping")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let startResult = try await server.callToolResult(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
                "deviceUDID": .string(deviceUDID),
                "headless": .bool(true),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        #expect(startResult.isError != true, "iOS preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startResult.content)
        let info = try MCPTestServer.decodeStructured(StartInfo.self, from: startResult)
        guard let port = info.appServerPort else {
            Issue.record("preview_start did not return an app server port")
            return
        }
        try await Task.sleep(for: .seconds(3))

        // Control: a drag over /control scrolls the list, proving the
        // daemon-hosted server forwards input to IndigoHID.
        let beforeDrag = try await server.snapshotBytes(sessionID: sessionID)
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control")!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(#"{"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}"#.utf8)
        let (_, response) = try await URLSession.shared.data(for: request)
        #expect((response as? HTTPURLResponse)?.statusCode == 200, "control POST should return 200")
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeDrag, timeout: .seconds(10))

        // Stream: the in-process capture serves a real JPEG over /stream.mjpeg.
        let sample = try await readStreamSample(port: port, limit: 20_000)
        #expect(
            sample.range(of: Data([0xFF, 0xD8, 0xFF])) != nil,
            "stream should carry a real JPEG frame")

        _ = try await server.callToolResult(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)])
    }
}

/// Read a bounded sample of an MJPEG stream, asserting the multipart content
/// type. URLSession unwraps multipart/x-mixed-replace and delivers the JPEG
/// part bodies without the boundary.
private func readStreamSample(port: Int, limit: Int) async throws -> Data {
    var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/stream.mjpeg")!)
    request.timeoutInterval = 15
    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    let contentType = (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") ?? ""
    #expect(contentType.contains("multipart/x-mixed-replace"), "stream should be MJPEG multipart")

    var buffer = Data()
    let deadline = ContinuousClock.now + .seconds(10)
    for try await byte in bytes {
        buffer.append(byte)
        if buffer.count >= limit || ContinuousClock.now >= deadline { break }
    }
    return buffer
}

/// Verifies the PreviewAppServer MJPEG plumbing with a stub frame source. No
/// simulator: in production the real EventDrivenFrameSource runs in the daemon,
/// in-process with the session that owns the display.
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

        let sample = try await readStreamSample(port: Int(port), limit: 256)
        #expect(sample.range(of: jpeg) != nil, "stream should carry the source JPEG bytes")
    }
}

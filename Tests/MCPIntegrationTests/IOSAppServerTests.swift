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
        let hid = try await SimulatorManager().makeHIDClient(udid: deviceUDID)
        let appServer = PreviewAppServer(sink: IndigoHIDInputSink(client: hid))
        let port = try await appServer.start()
        defer { appServer.stop() }

        func control(_ body: String) async throws {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/control")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = Data(body.utf8)
            let (_, response) = try await URLSession.shared.data(for: request)
            #expect((response as? HTTPURLResponse)?.statusCode == 200, "control POST should return 200")
        }

        // Drag over the control channel to scroll the list. A vertical drag over
        // the list changes the framebuffer on any device, proving the POST drove
        // the hosted scene through the IndigoHID sink. (Tap-on-a-control is
        // device-position-sensitive and is covered at the sink in
        // IOSHIDInputTests; tap and drag share this same /control pipe.)
        let beforeDrag = try await server.snapshotBytes(sessionID: sessionID)
        try await control(#"{"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}"#)
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeDrag, timeout: .seconds(10))

        _ = try await server.callTool(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)])
    }
}

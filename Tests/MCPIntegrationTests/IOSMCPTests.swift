import Foundation
import MCP
import Testing

/// All iOS MCP tests share a single server process and session to avoid
/// repeated simulator boot and compilation overhead.
@Suite("MCP iOS integration", .serialized)
struct IOSMCPTests {

    private static func hasIOSSimulator() async -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        process.arguments = ["simctl", "list", "devices", "available"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let output =
                String(
                    data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return output.contains("iPhone")
        } catch {
            return false
        }
    }

    // MARK: - simulator_list (requires CoreSimulator; ios-tests job warms daemon)

    @Test("simulator_list returns available devices", .timeLimit(.minutes(10)))
    func simulatorListReturnsDevices() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let (content, isError) = try await server.callTool(name: "simulator_list")

        #expect(isError != true, "simulator_list should succeed")
        let text = MCPTestServer.extractText(from: content)
        let uuidPattern =
            /[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}/
        #expect(
            text.firstMatch(of: uuidPattern) != nil, "Should contain at least one device UDID")
    }

    // MARK: - Full iOS workflow

    @Test(
        "iOS preview workflow: start, snapshot, elements, tap, swipe, switch",
        // 20 minutes matches the ios-tests step timeout (ci.yml). The
        // workflow does compile-dylib + build-host-app + boot (up to
        // 600s under CI load) + install + launch + 6 more tool calls
        // end-to-end in a single test. Observed on PR #141 CI: the
        // pre-launch preamble alone consumed 300–500s when the GHA
        // macos-15 runner was under combined build+multi-test load;
        // the prior 10-minute limit truncated before boot completed.
        .timeLimit(.minutes(20)))
    func fullIOSWorkflow() async throws {
        // Pick this test's assigned device (index 2) so we don't contend
        // with SimulatorManagerTests (index 0) or IOSPreviewSessionTests
        // (index 1) when Swift Testing runs the iOS suites in parallel.
        // See IOSSimulatorPicker for the full assignment table.
        guard let deviceUDID = try await IOSSimulatorPicker.pickUDID(index: 2) else {
            print("No iOS simulator at picker index 2 — skipping iOS MCP tests")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // --- Start iOS preview (single preview_start for all iOS assertions) ---
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

        // --- Snapshot ---
        let (snapshotContent, snapshotError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)]
        )
        #expect(snapshotError != true, "iOS snapshot should succeed")
        try MCPTestServer.assertValidImage(snapshotContent)

        // --- Elements with accessibility assertions ---
        let (elementsContent, elementsError) = try await server.callTool(
            name: "preview_elements",
            arguments: [
                "sessionID": .string(sessionID),
                "filter": .string("all"),
            ]
        )
        #expect(elementsError != true, "preview_elements should succeed")
        let elementsText = MCPTestServer.extractText(from: elementsContent)
        #expect(!elementsText.isEmpty, "Should return accessibility data")
        #expect(elementsText.contains("My Items"), "Should contain navigation title")
        #expect(elementsText.contains("Show Completed"), "Should contain toggle")
        #expect(elementsText.contains("Design UI"), "Should contain first item")
        #expect(elementsText.contains("Write code"), "Should contain second item")
        #expect(elementsText.contains("Ship it"), "Should contain fourth item")

        // --- Tap ---
        let (tapContent, tapError) = try await server.callTool(
            name: "preview_touch",
            arguments: [
                "sessionID": .string(sessionID),
                "x": .double(200),
                "y": .double(400),
                "action": .string("tap"),
            ]
        )
        #expect(tapError != true, "Tap should succeed")
        let tapText = MCPTestServer.extractText(from: tapContent)
        #expect(tapText.contains("Tap sent"), "Should confirm tap: \(tapText)")

        // --- Swipe ---
        let (swipeContent, swipeError) = try await server.callTool(
            name: "preview_touch",
            arguments: [
                "sessionID": .string(sessionID),
                "x": .double(300),
                "y": .double(400),
                "action": .string("swipe"),
                "toX": .double(100),
                "toY": .double(400),
            ]
        )
        #expect(swipeError != true, "Swipe should succeed")
        let swipeText = MCPTestServer.extractText(from: swipeContent)
        #expect(swipeText.contains("Swipe"), "Should confirm swipe: \(swipeText)")

        // --- Switch to empty state and verify elements ---
        _ = try await server.callTool(
            name: "preview_switch",
            arguments: [
                "sessionID": .string(sessionID),
                "previewIndex": .int(1),
            ]
        )
        try await Task.sleep(for: .seconds(2))

        let (emptyElements, _) = try await server.callTool(
            name: "preview_elements",
            arguments: [
                "sessionID": .string(sessionID),
                "filter": .string("all"),
            ]
        )
        let emptyText = MCPTestServer.extractText(from: emptyElements)
        #expect(!emptyText.contains("Design UI"), "Empty state should not contain item rows")
        #expect(!emptyText.contains("Write code"), "Empty state should not contain item rows")

        // --- Stop ---
        _ = try await server.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
    }
}

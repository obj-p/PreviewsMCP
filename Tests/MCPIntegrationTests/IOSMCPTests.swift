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

    @Test(
        "iOS preview workflow: start, snapshot, elements, tap, swipe, switch",
        .timeLimit(.minutes(5)))
    func fullIOSWorkflow() async throws {
        guard await Self.hasIOSSimulator() else {
            print("No iOS simulator available — skipping iOS MCP tests")
            return
        }

        let server = try await MCPTestServer.start()
        defer { Task { await server.stop() } }

        // --- Start iOS preview (single preview_start for all iOS assertions) ---
        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
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

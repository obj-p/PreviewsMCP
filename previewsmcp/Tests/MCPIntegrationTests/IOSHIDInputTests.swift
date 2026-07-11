import Foundation
import MCP
import PreviewsIOS
import PreviewsTestSupport
@preconcurrency import SimulatorBridge
import Testing

/// Verifies the daemon-side IndigoHID input path (SBHIDClient) drives the hosted
/// agent scene through the shell: a digitizer tap flips the SwiftUI toggle, and
/// a digitizer drag scrolls the list. Independent of the in-app host-app touch
/// path that `preview_touch` uses.
@Suite("iOS IndigoHID input", .serialized)
struct IOSHIDInputTests {
    @Test(
        "IndigoHID tap flips the toggle and drag scrolls the list",
        .timeLimit(.minutes(20)),
        .disabled(
            if: ProcessInfo.processInfo.environment["CI"] != nil,
            "boots a simulator + compiles a preview; local-only like fullIOSWorkflow"
        )
    )
    func tapAndDrag() async throws {
        // Serialized against the other heavy iOS e2e suites — see the note in
        // IOSAppServerTests.appServerEndToEnd — and against sim-booting runs
        // from other checkouts (#336).
        let simLock = try await SimulatorTestLock.acquire()
        defer { simLock.release() }
        let lock = try await DaemonTestLock.acquire()
        defer { lock.release() }

        // Reset host-global CoreSimulator state once before the first iOS
        // preview boots — earlier Bazel targets leave it degraded (see
        // CoreSimulatorHygiene).
        await CoreSimulatorHygiene.resetOnce()

        guard let deviceUDID = await SimulatorTestDevices.udid(index: 2) else {
            print("No dedicated test simulator for index 2 — skipping")
            return
        }

        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // preview_start pays first-boot + cold example build on a fresh
        // machine — see IOSMCPTests for the 600s rationale.
        let (startContent, startError) = try await server.callToolWithTimeout(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "platform": .string("ios"),
                "deviceUDID": .string(deviceUDID),
                "headless": .bool(true),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ],
            timeout: .seconds(600)
        )
        #expect(startError != true, "iOS preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)
        try await Task.sleep(for: .seconds(3))

        let hid = try await SimulatorManager().makeHIDClient(udid: deviceUDID)

        // Tap the "Show Completed" toggle (normalized). Flipping it hides the
        // completed rows, a visible change, which proves the digitizer tap
        // reached the hosted agent scene through the shell and fired the real
        // SwiftUI action.
        let beforeTap = try await server.snapshotBytes(sessionID: sessionID)
        #expect(hid.tapAt(x: 0.86, y: 0.39), "HID symbol should resolve")
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeTap, timeout: .seconds(10)
        )

        // Toggle back on so the list is long enough to scroll, then drag and
        // confirm the framebuffer changes again.
        #expect(hid.tapAt(x: 0.86, y: 0.39), "HID symbol should resolve")
        try await Task.sleep(for: .seconds(1))

        let beforeDrag = try await server.snapshotBytes(sessionID: sessionID)
        #expect(
            hid.dragFrom(x: 0.5, fromY: 0.7, toX: 0.5, toY: 0.3, steps: 12),
            "HID symbol should resolve"
        )
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeDrag, timeout: .seconds(10)
        )

        _ = try await server.callTool(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
        )
    }
}

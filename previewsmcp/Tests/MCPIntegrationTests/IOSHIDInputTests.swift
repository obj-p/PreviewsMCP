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
    private static let toggleLabel = "Show Completed"
    private static let maximumTapAttempts = 3

    @Test(
        "IndigoHID tap flips the toggle and drag scrolls the list",
        .timeLimit(.minutes(20))
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

        guard let deviceUDID = try await SimulatorTestDevices.udid(index: 2) else {
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

        // Tap the "Show Completed" toggle (normalized). Verify its logical
        // accessibility value so a delivered-but-unrecognized HID gesture can
        // be retried instead of surfacing #368's residual false red.
        let initialToggleValue = try await server.awaitElementValue(
            sessionID: sessionID,
            label: Self.toggleLabel,
            timeout: .seconds(30)
        )
        let beforeTap = try await server.snapshotBytes(sessionID: sessionID)
        let hiddenToggleValue = try await tapToggleUntilValueChanges(
            hid: hid,
            server: server,
            sessionID: sessionID,
            baseline: initialToggleValue
        )
        #expect(hiddenToggleValue != initialToggleValue)
        let afterTap = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: beforeTap, timeout: .seconds(10)
        )

        // Toggle back on so the list is long enough to scroll, then drag and
        // confirm the framebuffer changes again.
        let restoredToggleValue = try await tapToggleUntilValueChanges(
            hid: hid,
            server: server,
            sessionID: sessionID,
            baseline: hiddenToggleValue
        )
        #expect(restoredToggleValue == initialToggleValue)
        let beforeDrag = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: afterTap, timeout: .seconds(10)
        )
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

    private func tapToggleUntilValueChanges(
        hid: SBHIDClient,
        server: MCPTestServer,
        sessionID: String,
        baseline: String
    ) async throws -> String {
        let changedValue = try await TestRetry.firstSuccess(
            maximumAttempts: Self.maximumTapAttempts
        ) { attempt in
            try #require(hid.tapAt(x: 0.86, y: 0.39), "HID symbol should resolve")
            let value = try await server.waitForElementValueChange(
                sessionID: sessionID,
                label: Self.toggleLabel,
                baseline: baseline,
                timeout: .seconds(3)
            )
            if value == nil, attempt < Self.maximumTapAttempts {
                print(
                    "\(Self.toggleLabel) stayed \(baseline.debugDescription) after HID tap "
                        + "\(attempt)/\(Self.maximumTapAttempts) — retrying"
                )
            }
            return value
        }

        guard let changedValue else {
            Issue.record(
                "\(Self.toggleLabel) stayed \(baseline.debugDescription) after \(Self.maximumTapAttempts) HID taps. Server stderr:\n\(server.stderrLog())"
            )
            throw MCPTestError.timedOut(
                operation: "tapToggleUntilValueChanges", duration: .seconds(9)
            )
        }
        return changedValue
    }
}

import Foundation
import MCP
import Testing

@testable import PreviewsCLI

/// All macOS MCP tests share a single server process to avoid repeated
/// swift build / swiftc overhead. Tests are serialized and reuse sessions
/// where possible.
@Suite("MCP macOS integration", .serialized)
struct MacOSMCPTests {

    // MARK: - Session lifecycle, snapshots, switch, configure, hot reload

    @Test("Full macOS MCP workflow", .timeLimit(.minutes(10)))
    func fullMacOSWorkflow() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // --- preview_start returns session ID and available previews ---
        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        #expect(startError != true, "preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)
        #expect(sessionID.count == 36, "Session ID should be UUID format")

        let startText = MCPTestServer.extractText(from: startContent)
        #expect(startText.contains("[0]"), "Should list preview index 0")
        #expect(startText.contains("[1]"), "Should list preview index 1")
        #expect(startText.contains("Empty State"), "Should show Empty State preview")
        #expect(startText.contains("<- active"), "Should mark active preview")

        try await Task.sleep(for: .milliseconds(500))

        // --- preview_snapshot returns JPEG ---
        let (jpegContent, jpegError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)]
        )
        #expect(jpegError != true, "Snapshot should succeed")
        try MCPTestServer.assertValidImage(
            jpegContent, expectedMimeType: "image/jpeg", minSize: 10_000)

        // --- preview_snapshot returns PNG when quality >= 1.0 ---
        let (pngContent, _) = try await server.callTool(
            name: "preview_snapshot",
            arguments: [
                "sessionID": .string(sessionID),
                "quality": .double(1.0),
            ]
        )
        try MCPTestServer.assertValidImage(
            pngContent, expectedMimeType: "image/png",
            minSize: 10_000, expectedWidth: 400, expectedHeight: 600)
        let (data0, _) = try MCPTestServer.extractImageData(from: jpegContent)

        // --- preview_switch to valid index ---
        let (switchContent, switchError) = try await server.callTool(
            name: "preview_switch",
            arguments: [
                "sessionID": .string(sessionID),
                "previewIndex": .int(1),
            ]
        )
        #expect(switchError != true, "Switch should succeed")
        let switchText = MCPTestServer.extractText(from: switchContent)
        #expect(switchText.contains("Switched to preview 1"), "Should confirm switch")

        try await Task.sleep(for: .milliseconds(500))

        // --- Snapshot after switch should differ ---
        let (content1, _) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)]
        )
        let (data1, _) = try MCPTestServer.extractImageData(from: content1)
        #expect(data0 != data1, "Snapshots of different previews should differ")

        // --- preview_switch to invalid index rolls back ---
        var switchFailed = false
        do {
            let (_, err) = try await server.callTool(
                name: "preview_switch",
                arguments: [
                    "sessionID": .string(sessionID),
                    "previewIndex": .int(99),
                ]
            )
            switchFailed = err == true
        } catch {
            switchFailed = true
        }
        #expect(switchFailed, "Switch to invalid index should fail")

        // Snapshot after failed switch should still work (rollback)
        try await Task.sleep(for: .milliseconds(500))
        let (rollbackContent, rollbackError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)]
        )
        #expect(rollbackError != true, "Snapshot after failed switch should succeed")
        try MCPTestServer.assertValidImage(rollbackContent)

        // Switch back to preview 0 for configure tests
        _ = try await server.callTool(
            name: "preview_switch",
            arguments: [
                "sessionID": .string(sessionID),
                "previewIndex": .int(0),
            ]
        )

        // --- preview_configure colorScheme ---
        let (colorConfig, colorErr) = try await server.callTool(
            name: "preview_configure",
            arguments: [
                "sessionID": .string(sessionID),
                "colorScheme": .string("dark"),
            ]
        )
        #expect(colorErr != true, "Configure colorScheme should succeed")
        let colorText = MCPTestServer.extractText(from: colorConfig)
        #expect(colorText.contains("colorScheme=dark"), "Should confirm dark color scheme")
        #expect(colorText.contains("Configured session"), "Should confirm configuration")

        // --- preview_configure dynamicTypeSize (merge semantics — colorScheme preserved) ---
        let (dtsConfig, dtsErr) = try await server.callTool(
            name: "preview_configure",
            arguments: [
                "sessionID": .string(sessionID),
                "dynamicTypeSize": .string("large"),
            ]
        )
        #expect(dtsErr != true, "Configure dynamicTypeSize should succeed")
        let dtsText = MCPTestServer.extractText(from: dtsConfig)
        #expect(dtsText.contains("colorScheme=dark"), "colorScheme should be preserved (merge)")
        #expect(dtsText.contains("dynamicTypeSize=large"), "dynamicTypeSize should be set")

        // --- preview_configure with no traits ---
        let (noTraitConfig, _) = try await server.callTool(
            name: "preview_configure",
            arguments: ["sessionID": .string(sessionID)]
        )
        let noTraitText = MCPTestServer.extractText(from: noTraitConfig)
        #expect(
            noTraitText.contains("No configuration changes specified"),
            "Should indicate no changes")

        // --- preview_configure invalid trait ---
        let (_, invalidErr) = try await server.callTool(
            name: "preview_configure",
            arguments: [
                "sessionID": .string(sessionID),
                "colorScheme": .string("purple"),
            ]
        )
        #expect(invalidErr == true, "Invalid colorScheme should return error")

        // --- Traits persist across switch ---
        let (traitSwitch, traitSwitchErr) = try await server.callTool(
            name: "preview_switch",
            arguments: [
                "sessionID": .string(sessionID),
                "previewIndex": .int(1),
            ]
        )
        #expect(traitSwitchErr != true, "Switch should succeed")
        let traitSwitchText = MCPTestServer.extractText(from: traitSwitch)
        #expect(
            traitSwitchText.contains("colorScheme=dark"), "Traits should persist across switch")

        // --- preview_stop ---
        let (stopContent, stopError) = try await server.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
        #expect(stopError != true)
        let stopText = MCPTestServer.extractText(from: stopContent)
        #expect(stopText.contains("closed"), "Stop should confirm closure")

        // --- preview_stop nonexistent session ---
        // Must be rejected with isError so stop --session <typo> surfaces
        // a real error instead of a phantom "closed" success.
        let (fakeStop, fakeIsError) = try await server.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string("00000000-0000-0000-0000-000000000000")]
        )
        #expect(fakeIsError == true, "Stopping a nonexistent session must return isError")
        let fakeStopText = MCPTestServer.extractText(from: fakeStop)
        #expect(
            fakeStopText.contains("No session found"),
            "Should surface a 'No session found' message: \(fakeStopText)"
        )

        // --- preview_snapshot nonexistent session ---
        // Before this fix, a typo'd UUID fell through to `window(for:)`
        // which returned nil and threw `SnapshotError.captureFailed` —
        // a misleading message that suggested a capture failure rather
        // than a missing session. Must now be a clean isError with a
        // clear message.
        let (fakeSnap, fakeSnapIsError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string("00000000-0000-0000-0000-000000000000")]
        )
        #expect(fakeSnapIsError == true, "Snapshotting a nonexistent session must return isError")
        let fakeSnapText = MCPTestServer.extractText(from: fakeSnap)
        #expect(
            fakeSnapText.contains("No session found"),
            "Should surface a 'No session found' message: \(fakeSnapText)"
        )
    }

    // MARK: - structuredContent contract (wire format)

    /// Pin the daemon's `structuredContent` payloads for the 7 migrated
    /// tools. Deliberately decodes through the same `DaemonProtocol`
    /// DTOs that the CLI will consume, so drift in field names or
    /// shapes shows up here.
    @Test("structuredContent payloads decode for each migrated tool", .timeLimit(.minutes(10)))
    func structuredContentPayloadsDecode() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // preview_list — file + previews list, no session yet
        let listResult = try await server.callToolResult(
            name: "preview_list",
            arguments: ["filePath": .string(MCPTestServer.toDoViewPath)]
        )
        let list = try MCPTestServer.decodeStructured(
            DaemonProtocol.PreviewListResult.self, from: listResult
        )
        #expect(list.file.hasSuffix("ToDoView.swift"))
        #expect(list.previews.count >= 2)
        #expect(list.previews.allSatisfy { !$0.active }, "no session active → no active flag")

        // preview_start — session + platform + previews + activeIndex
        let startResult = try await server.callToolResult(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        let start = try MCPTestServer.decodeStructured(
            DaemonProtocol.PreviewStartResult.self, from: startResult
        )
        #expect(start.sessionID.count == 36)
        #expect(start.platform == "macos")
        #expect(start.activeIndex == 0)
        #expect(start.previews.first(where: { $0.index == 0 })?.active == true)

        let sessionID = start.sessionID

        // preview_switch — activeIndex reflects the switch
        let switchResult = try await server.callToolResult(
            name: "preview_switch",
            arguments: [
                "sessionID": .string(sessionID),
                "previewIndex": .int(1),
            ]
        )
        let switched = try MCPTestServer.decodeStructured(
            DaemonProtocol.SwitchResult.self, from: switchResult
        )
        #expect(switched.sessionID == sessionID)
        #expect(switched.activeIndex == 1)
        #expect(switched.previews.first(where: { $0.index == 1 })?.active == true)

        // preview_variants — label + status + imageIndex for each variant
        let variantsResult = try await server.callToolResult(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([.string("light"), .string("dark")]),
            ]
        )
        let variants = try MCPTestServer.decodeStructured(
            DaemonProtocol.VariantsResult.self, from: variantsResult
        )
        #expect(variants.variants.count == 2)
        #expect(variants.successCount == 2)
        #expect(variants.failCount == 0)
        for v in variants.variants {
            #expect(v.status == "ok")
            #expect(v.imageIndex != nil)
            // Image index must address a valid .image block
            let blocks = variantsResult.content
            if let idx = v.imageIndex, idx < blocks.count,
                case .image = blocks[idx]
            {
                // ok
            } else {
                Issue.record("imageIndex \(String(describing: v.imageIndex)) does not point at an image block")
            }
        }

        // session_list — returns our one session
        let sessionListResult = try await server.callToolResult(name: "session_list")
        let sessions = try MCPTestServer.decodeStructured(
            DaemonProtocol.SessionListResult.self, from: sessionListResult
        )
        #expect(sessions.sessions.contains { $0.sessionID == sessionID && $0.platform == "macos" })

        // simulator_list — always decodes (empty array if no simulators)
        let simsResult = try await server.callToolResult(name: "simulator_list")
        _ = try MCPTestServer.decodeStructured(
            DaemonProtocol.SimulatorListResult.self, from: simsResult
        )

        // Cleanup
        _ = try await server.callTool(
            name: "preview_stop", arguments: ["sessionID": .string(sessionID)]
        )
    }

    // MARK: - preview_variants

    @Test("preview_variants captures multiple configurations", .timeLimit(.minutes(20)))
    func previewVariants() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // Start a session
        let (startContent, startError) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(MCPTestServer.toDoViewPath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        #expect(startError != true, "preview_start should succeed")
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)

        try await Task.sleep(for: .milliseconds(500))

        // --- Preset variants: light + dark ---
        let (varContent, varError) = try await server.callTool(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([.string("light"), .string("dark")]),
            ]
        )
        #expect(varError != true, "preview_variants should succeed")

        let images = MCPTestServer.extractImages(from: varContent)
        #expect(images.count == 2, "Should return 2 images for 2 variants")
        #expect(images[0].mimeType == "image/jpeg", "Default format should be JPEG")

        let varText = MCPTestServer.extractText(from: varContent)
        #expect(varText.contains("[0] light:"), "Should have label for light variant")
        #expect(varText.contains("[1] dark:"), "Should have label for dark variant")

        // Images should differ (light vs dark)
        #expect(images[0].data != images[1].data, "Light and dark screenshots should differ")

        // --- Custom JSON object variant ---
        let customJSON = #"{"colorScheme":"dark","dynamicTypeSize":"large","label":"dark-large"}"#
        let (customContent, customError) = try await server.callTool(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([.string(customJSON)]),
            ]
        )
        #expect(customError != true, "Custom JSON variant should succeed")
        let customImages = MCPTestServer.extractImages(from: customContent)
        #expect(customImages.count == 1, "Should return 1 image for custom variant")
        let customText = MCPTestServer.extractText(from: customContent)
        #expect(customText.contains("dark-large"), "Should use custom label")

        // --- Trait restoration: session should return to default traits ---
        // Set traits to dark before variants call
        let (configContent, configErr) = try await server.callTool(
            name: "preview_configure",
            arguments: [
                "sessionID": .string(sessionID),
                "colorScheme": .string("dark"),
            ]
        )
        #expect(configErr != true, "preview_configure should succeed")
        let configText = MCPTestServer.extractText(from: configContent)
        #expect(configText.contains("colorScheme=dark"), "Should be dark before variants")

        // Run variants with light only
        let (restoreContent, restoreErr) = try await server.callTool(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([.string("light")]),
            ]
        )
        #expect(restoreErr != true, "Restore variants should succeed")
        let restoreImages = MCPTestServer.extractImages(from: restoreContent)
        #expect(restoreImages.count == 1)

        // Verify traits were restored to dark (the pre-variants state).
        // Configure dynamicTypeSize only — if colorScheme was restored to dark,
        // the response should show both colorScheme=dark AND dynamicTypeSize.
        let (checkContent, checkErr) = try await server.callTool(
            name: "preview_configure",
            arguments: [
                "sessionID": .string(sessionID),
                "dynamicTypeSize": .string("large"),
            ]
        )
        #expect(checkErr != true)
        let checkText = MCPTestServer.extractText(from: checkContent)
        #expect(
            checkText.contains("colorScheme=dark"),
            "colorScheme should have been restored to dark after preview_variants"
        )

        // --- Empty variants → error ---
        let (_, emptyErr) = try await server.callTool(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([]),
            ]
        )
        #expect(emptyErr == true, "Empty variants should return error")

        // --- Invalid preset → error ---
        let (invalidContent, invalidErr) = try await server.callTool(
            name: "preview_variants",
            arguments: [
                "sessionID": .string(sessionID),
                "variants": .array([.string("neon")]),
            ]
        )
        #expect(invalidErr == true, "Invalid preset should return error")
        let invalidText = MCPTestServer.extractText(from: invalidContent)
        #expect(invalidText.contains("neon"), "Error should mention the invalid preset")

        // --- Cleanup ---
        _ = try await server.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
    }

    // MARK: - Hot reload (separate tests — modify source file)

    /// Literal-only fast path: change a string literal, which the DesignTimeStore
    /// tracker in PreviewSession.tryLiteralUpdate applies without recompiling.
    /// Sync target: "Literal-only change:" log line from HostApp.swift.
    @Test("File edit triggers hot reload (literal-only fast path)", .timeLimit(.minutes(10)))
    func hotReloadLiteralOnly() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let filePath = MCPTestServer.toDoViewPath
        let originalContent = try String(contentsOfFile: filePath, encoding: .utf8)
        defer {
            try? originalContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        let (startContent, _) = try await server.callToolWithTimeout(
            name: "preview_start",
            arguments: [
                "filePath": .string(filePath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)

        let baseline = try await server.snapshotBytes(sessionID: sessionID)

        // "Progress" is in the first SummaryCard (page 0 of the TabView), visibly
        // rendered in headless NSHostingView — required for the byte-diff assertion.
        let modified = originalContent.replacingOccurrences(of: "\"Progress\"", with: "\"Totals\"")
        #expect(modified != originalContent, "Replacement should have changed the content")
        try modified.write(
            to: URL(fileURLWithPath: filePath), atomically: false, encoding: .utf8)

        try await server.awaitStderrContains("Literal-only change:", timeout: .seconds(30))
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: baseline, timeout: .seconds(10)
        )

        _ = try await server.callToolWithTimeout(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
    }

    /// Structural slow path: add a new view modifier call, which the literal differ
    /// cannot fast-path, forcing a full swiftc recompile and dylib reload.
    /// Sync target: "Compiled:" log line from HostApp.swift after swiftc finishes.
    @Test("File edit triggers hot reload (structural recompile path)", .timeLimit(.minutes(10)))
    func hotReloadStructural() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let filePath = MCPTestServer.toDoViewPath
        let originalContent = try String(contentsOfFile: filePath, encoding: .utf8)
        defer {
            try? originalContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        let (startContent, _) = try await server.callToolWithTimeout(
            name: "preview_start",
            arguments: [
                "filePath": .string(filePath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)

        let baseline = try await server.snapshotBytes(sessionID: sessionID)

        // Add a new view modifier — adding a call node forces .structural from LiteralDiffer.
        let modified = originalContent.replacingOccurrences(
            of: ".navigationTitle(\"My Items\")",
            with: ".navigationTitle(\"My Items\").padding(32)"
        )
        #expect(modified != originalContent, "Replacement should have changed the content")
        try modified.write(
            to: URL(fileURLWithPath: filePath), atomically: false, encoding: .utf8)

        // CI swiftc on cold caches is slow; AGENTS.md notes daemon startup alone is 5–10s.
        try await server.awaitStderrContains("Compiled:", timeout: .seconds(90))
        _ = try await server.awaitSnapshotChange(
            sessionID: sessionID, baseline: baseline, timeout: .seconds(15)
        )

        _ = try await server.callToolWithTimeout(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
    }

    // MARK: - Liveness heartbeat

    /// The daemon emits a `LogMessageNotification` with `logger: "heartbeat"`
    /// every 2s, unconditional of whether any tool call is in flight. This
    /// gives client-side stall detectors (Phase 2, future PR) a liveness
    /// signal that distinguishes "busy" from "wedged" — particularly
    /// important for the FileWatcher hot-reload path where today's silence
    /// spans the full swiftc recompile with no other MCP traffic.
    ///
    /// This test idles for 6s and asserts at least 2 heartbeats arrive.
    /// The first heartbeat fires at T+2s relative to `server.start` (not
    /// subprocess spawn), so a 6s idle window guarantees a two-ping
    /// margin even if subprocess boot eats half a second.
    @Test(
        "daemon emits unconditional 2s heartbeat notifications",
        .timeLimit(.minutes(1))
    )
    func daemonEmitsHeartbeat() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        // Idle, without issuing any tool calls. Heartbeats must fire
        // regardless of request activity.
        try await Task.sleep(for: .seconds(6))

        let observed = server.observedHeartbeatCount()
        #expect(
            observed >= 2,
            "expected ≥2 heartbeats in a 6s idle window (got \(observed))"
        )
    }

    // MARK: - Timeout primitive

    /// Regression guard for `MCPTestServer.withTimeout`. The prior
    /// implementation used `withThrowingTaskGroup` + `Task.sleep(for:)`,
    /// which does not fire when the cooperative thread pool is starved by
    /// a busy-spin in the body — the pattern that caused CI runs
    /// 72323677364, 72328816376, and 72345678664 to go silent for ten
    /// minutes and then be killed by Swift Testing's outer `.timeLimit`.
    /// The replacement uses a detached `Thread` (pthread) timer and
    /// resumes a shared `CheckedContinuation` directly, both of which
    /// sidestep Swift concurrency scheduling.
    ///
    /// The body blocks via POSIX `sleep(3)` — a kernel-level blocking call
    /// that holds its cooperative thread without yielding. Under that
    /// condition the `Task.sleep`-based implementation would silently
    /// miss its deadline; the pthread implementation fires and resumes
    /// the outer continuation. `Thread.sleep(forTimeInterval:)` is
    /// annotated unavailable in async contexts in newer toolchains; plain
    /// `sleep()` has no such annotation and is equivalent for this test.
    @Test(
        "withTimeout pthread timer fires under cooperative-pool starvation",
        .timeLimit(.minutes(1))
    )
    func withTimeoutFiresUnderStarvation() async throws {
        // The pthread calls `process.terminate()` on timeout; a harmless
        // long-running subprocess gives it a real target without pulling
        // in the full MCPTestServer lifecycle (which would entangle this
        // test with MCP-client state that isn't under test here).
        //
        // Route stdio to /dev/null to match MCPTestServer.start()'s hardened
        // pattern (see its comment on inherited stderr wedging CI runners
        // on macOS 15). `/bin/sleep` is silent in practice, but leaking
        // child handles has bitten this codebase before.
        let dummy = Process()
        dummy.executableURL = URL(fileURLWithPath: "/bin/sleep")
        dummy.arguments = ["60"]
        dummy.standardInput = FileHandle.nullDevice
        dummy.standardOutput = FileHandle.nullDevice
        dummy.standardError = FileHandle.nullDevice
        try dummy.run()
        defer {
            if dummy.isRunning { dummy.terminate() }
        }

        let budget = Duration.seconds(2)
        let start = ContinuousClock.now
        await #expect(throws: Error.self) {
            _ = try await MCPTestServer.withTimeout(budget, process: dummy) {
                // Occupy a cooperative thread without yielding. This is
                // the condition the pthread timer is built to survive.
                sleep(60)
                return ()
            }
        }
        let elapsed = (ContinuousClock.now - start).asTimeInterval

        // Upper bound absorbs thread-creation + continuation-resume
        // overhead. If the timer doesn't fire at all, the enclosing
        // `.timeLimit(.minutes(1))` catches it.
        #expect(
            elapsed >= 2 && elapsed < 5,
            "expected timeout within 2–5s (got \(elapsed)s)"
        )
        #expect(
            !dummy.isRunning,
            "subprocess should be terminated by the pthread on timeout"
        )
    }
}

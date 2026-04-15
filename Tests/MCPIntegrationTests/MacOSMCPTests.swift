import Foundation
import MCP
import Testing

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

    // MARK: - preview_variants

    @Test("preview_variants captures multiple configurations", .timeLimit(.minutes(10)))
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

    // MARK: - Hot reload (separate test — modifies source file)

    @Test("File edit triggers hot reload", .timeLimit(.minutes(3)))
    func hotReload() async throws {
        let server = try await MCPTestServer.start()
        defer { server.stop() }

        let filePath = MCPTestServer.toDoViewPath
        let originalContent = try String(contentsOfFile: filePath, encoding: .utf8)
        defer {
            try? originalContent.write(toFile: filePath, atomically: true, encoding: .utf8)
        }

        let (startContent, _) = try await server.callTool(
            name: "preview_start",
            arguments: [
                "filePath": .string(filePath),
                "projectPath": .string(MCPTestServer.spmExampleRoot.path),
            ]
        )
        let sessionID = try MCPTestServer.extractSessionID(from: startContent)

        try await Task.sleep(for: .milliseconds(500))

        // Edit source file
        let modified = originalContent.replacingOccurrences(of: "\"My Items\"", with: "\"Tasks\"")
        #expect(modified != originalContent, "Replacement should have changed the content")
        try modified.write(
            to: URL(fileURLWithPath: filePath), atomically: false, encoding: .utf8)

        // Wait for file watcher to detect change and reload.
        // File watcher polls every 0.5s; recompilation takes a few seconds.
        try await Task.sleep(for: .seconds(5))
        let (snapshotContent, snapshotError) = try await server.callTool(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)]
        )
        #expect(snapshotError != true, "Snapshot should succeed after hot reload")
        try MCPTestServer.assertValidImage(snapshotContent)

        _ = try await server.callTool(
            name: "preview_stop",
            arguments: ["sessionID": .string(sessionID)]
        )
    }
}

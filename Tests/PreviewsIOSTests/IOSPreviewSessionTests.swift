import Foundation
import Testing

@testable import PreviewsCore
@testable import PreviewsIOS

// Serialized so `endToEnd` and `endToEndUIViewBodyKindProbe` don't both boot
// a simulator at the same time. Two parallel boots inside a single iOS suite
// starve each other on CI macos-15 runners — the iOS-tests job timed out at
// 20 min on PR #163 with both tests running concurrently. The suite's
// per-test simulator picker (`IOSSimulatorPicker.pick(index:)`) prevents
// cross-suite contention; this trait covers the within-suite case.
@Suite("IOSPreviewSession", .serialized)
struct IOSPreviewSessionTests {

    static let testViewSource = """
        import SwiftUI

        struct HelloView: View {
            var body: some View {
                Text("Hello from iOS Simulator!")
                    .font(.largeTitle)
                    .padding()
            }
        }

        #Preview {
            HelloView()
        }
        """

    @Test("End-to-end: compile, boot, install, launch, screenshot")
    func endToEnd() async throws {
        // Write test source
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-ios-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.testViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Pick the picker's assigned device (index 1) — distinct from
        // SimulatorManagerTests.bootAndShutdown (index 0) and
        // IOSMCPTests.fullIOSWorkflow (index 2) so the three iOS suites
        // can run in parallel without contending for the same simulator.
        guard let target = try await IOSSimulatorPicker.pick(index: 1) else {
            print("No iOS simulator at picker index 1 — skipping e2e test")
            return
        }
        let simulatorManager = SimulatorManager()

        // Create session with isolated work dirs to avoid conflicts with other tests
        let hostWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-e2e-\(UUID().uuidString)")
        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder(workDir: hostWorkDir)
        defer { try? FileManager.default.removeItem(at: hostWorkDir) }
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            deviceUDID: target.udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager
        )

        // Start — this boots sim, installs host, compiles dylib, launches
        let pid = try await session.start()
        #expect(pid > 0)
        print("iOS preview launched with PID \(pid) on \(target.name)")

        // The init handshake (#160) probes the dylib's `previewBodyKind` symbol
        // and reports a wire kind back to the daemon. This source has a SwiftUI
        // body (HelloView), so the probe's compiler-resolved overload must
        // select `swiftUI`. Catches a future regression where the probe ends
        // up matching the wrong overload.
        let bodyKind = await session.currentBodyKind
        #expect(bodyKind == .swiftUI, "Expected SwiftUI body kind; got \(bodyKind)")

        // Test body wrapped so we always shut down
        var testError: (any Error)?
        do {
            // Wait for the app to render
            try await Task.sleep(for: .seconds(3))

            // Default quality → JPEG (0xFF 0xD8 SOI marker).
            let jpegData = try await session.screenshot()
            #expect(jpegData.count > 0)
            #expect(jpegData[0] == 0xFF && jpegData[1] == 0xD8)
            print("JPEG screenshot captured: \(jpegData.count) bytes")

            // Quality 1.0 → PNG (0x89 'P' header).
            let pngData = try await session.screenshot(jpegQuality: 1.0)
            #expect(pngData.count > 0)
            #expect(pngData[0] == 0x89 && pngData[1] == 0x50)
            print("PNG screenshot captured: \(pngData.count) bytes")

            // Save PNG for manual inspection.
            let screenshotPath = tempDir.appendingPathComponent("ios_preview.png")
            try pngData.write(to: screenshotPath)
            print("Saved to: \(screenshotPath.path)")
        } catch {
            testError = error
        }

        // Always shut down
        try? await simulatorManager.shutdownDevice(udid: target.udid)

        if let testError { throw testError }
    }

    static let testUIViewSource = """
        import SwiftUI
        import UIKit

        final class HelloUIView: UIView {
            init() {
                super.init(frame: .zero)
                backgroundColor = .systemGreen
                let label = UILabel()
                label.text = "Hello from UIKit"
                label.translatesAutoresizingMaskIntoConstraints = false
                addSubview(label)
                NSLayoutConstraint.activate([
                    label.centerXAnchor.constraint(equalTo: centerXAnchor),
                    label.centerYAnchor.constraint(equalTo: centerYAnchor),
                ])
            }
            required init?(coder: NSCoder) { fatalError() }
        }

        #Preview {
            HelloUIView()
        }
        """

    /// Companion to `endToEnd` that exercises the iOS UIKit branch of the
    /// `previewBodyKind` runtime probe (#160). Without this test the macOS
    /// `bodyKindProbeReturnsOneForSwiftUI` only validates the SwiftUI overload;
    /// any future regression where the probe's UIKit overload stops being
    /// selected at compile time would only be caught by the manual simulator
    /// hand-test referenced in the PR.
    @Test("End-to-end: UIView body — runtime probe reports .uiView (#160)")
    func endToEndUIViewBodyKindProbe() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-ios-uiview-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("HelloUIView.swift")
        try Self.testUIViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        // Picker index 3 — distinct from 0/1/2 used by SimulatorManagerTests,
        // IOSPreviewSessionTests.endToEnd, and IOSMCPTests so the four iOS
        // tests can boot in parallel without contending for the same device.
        guard let target = try await IOSSimulatorPicker.pick(index: 3) else {
            print("No iOS simulator at picker index 3 — skipping UIView probe test")
            return
        }
        let simulatorManager = SimulatorManager()

        let hostWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-uiview-\(UUID().uuidString)")
        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder(workDir: hostWorkDir)
        defer { try? FileManager.default.removeItem(at: hostWorkDir) }

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            deviceUDID: target.udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager
        )

        let pid = try await session.start()
        #expect(pid > 0)

        // The runtime probe runs at dylib load and is reported via the init
        // handshake during `start()`. By the time `start()` returns,
        // `currentBodyKind` reflects the kind the iOS dylib resolved. Snapshot
        // the value before shutdown so a failed expectation doesn't leak the
        // simulator.
        let bodyKind = await session.currentBodyKind
        try? await simulatorManager.shutdownDevice(udid: target.udid)

        #expect(
            bodyKind == .uiView,
            "Expected iOS UIView probe to return .uiView; got \(bodyKind)"
        )
    }
}

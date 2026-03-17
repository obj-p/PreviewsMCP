import Foundation
import Testing
@testable import PreviewsIOS
@testable import PreviewsCore

@Suite("IOSPreviewSession")
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

        // Find an available device — prefer already-booted to avoid sim cycling issues
        let simulatorManager = SimulatorManager()
        let devices = try await simulatorManager.listDevices()
        let available = devices.filter { $0.isAvailable }
        guard let target = available.first(where: { $0.state == .booted })
            ?? available.first else {
            print("No available simulator devices — skipping e2e test")
            return
        }

        // Create session with isolated work dirs to avoid conflicts with other tests
        let hostWorkDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-host-e2e-\(UUID().uuidString)")
        let compiler = try await Compiler(platform: .iOSSimulator)
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

        // Test body wrapped so we always shut down
        var testError: (any Error)?
        do {
            // Wait for the app to render
            try await Task.sleep(for: .seconds(3))

            // Screenshot
            let pngData = try await session.screenshot()
            #expect(pngData.count > 0)
            print("Screenshot captured: \(pngData.count) bytes")

            // Save screenshot for manual inspection
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
}

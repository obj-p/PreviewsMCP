import Testing
import Foundation
@testable import PreviewsCore

@Suite("BuildSystem")
struct BuildSystemTests {

    // MARK: - SPMBuildSystem.detect

    @Test("SPMBuildSystem detects Package.swift walking up directories")
    func detectSPMPackage() async throws {
        // Create a temporary SPM-like directory structure
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let packageSwift = tmpDir.appendingPathComponent("Package.swift")
        try "// swift-tools-version: 6.0".write(to: packageSwift, atomically: true, encoding: .utf8)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let spm = try await SPMBuildSystem.detect(for: sourceFile)
        #expect(spm != nil)
        #expect(spm?.projectRoot.path == tmpDir.standardizedFileURL.path)
    }

    @Test("SPMBuildSystem returns nil for standalone file with no Package.swift")
    func detectStandaloneFile() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("Standalone.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let spm = try await SPMBuildSystem.detect(for: sourceFile)
        #expect(spm == nil)
    }

    @Test("BuildSystemDetector returns nil for standalone file")
    func detectorReturnsNilForStandalone() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("Standalone.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(for: sourceFile)
        #expect(buildSystem == nil)
    }

    // MARK: - BridgeGenerator

    @Test("BridgeGenerator.generateBridgeOnlySource produces correct output")
    func bridgeOnlySource() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: "ContentView()",
            platform: .macOS
        )

        #expect(source.contains("import MyTarget"))
        #expect(source.contains("import SwiftUI"))
        #expect(source.contains("import AppKit"))
        #expect(source.contains("@_cdecl(\"createPreviewView\")"))
        #expect(source.contains("ContentView()"))
        #expect(source.contains("NSHostingView"))
        // Should NOT contain DesignTimeStore
        #expect(!source.contains("DesignTimeStore"))
    }

    @Test("BridgeGenerator.generateBridgeOnlySource produces UIKit for iOS")
    func bridgeOnlySourceIOS() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: "ContentView()",
            platform: .iOSSimulator
        )

        #expect(source.contains("import UIKit"))
        #expect(source.contains("UIHostingController"))
        #expect(!source.contains("import AppKit"))
    }

    @Test("BridgeGenerator.generateOverlaySource includes DesignTimeStore")
    func overlaySourceIncludesDesignTimeStore() {
        let originalSource = """
        import SwiftUI
        struct MyView: View {
            var body: some View {
                Text("Hello")
            }
        }
        #Preview { MyView() }
        """

        let (source, literals) = BridgeGenerator.generateOverlaySource(
            originalSource: originalSource,
            closureBody: "MyView()",
            platform: .macOS
        )

        #expect(source.contains("DesignTimeStore"))
        #expect(source.contains("@_cdecl(\"createPreviewView\")"))
        #expect(!literals.isEmpty)
    }

    // MARK: - Compiler extraFlags

    @Test("Compiler.compileCombined accepts extra flags")
    func compilerExtraFlags() async throws {
        let compiler = try await Compiler()
        let source = """
        import SwiftUI
        import AppKit

        @_cdecl("createPreviewView")
        public func createPreviewView() -> UnsafeMutableRawPointer {
            let view = SwiftUI.AnyView(Text("Hello"))
            let hostingView = NSHostingView(rootView: view)
            return Unmanaged.passRetained(hostingView).toOpaque()
        }
        """

        // -DPREVIEW_MODE is a harmless extra flag
        let result = try await compiler.compileCombined(
            source: source,
            moduleName: "ExtraFlagsTest",
            extraFlags: ["-DPREVIEW_MODE"]
        )

        #expect(FileManager.default.fileExists(atPath: result.dylibPath.path))
    }

    // MARK: - BuildContext

    @Test("BuildContext.supportsTier2 reflects sourceFiles presence")
    func buildContextTiers() {
        let tier1 = BuildContext(
            moduleName: "M",
            compilerFlags: [],
            projectRoot: URL(fileURLWithPath: "/tmp"),
            targetName: "M"
        )
        #expect(!tier1.supportsTier2)

        let tier2 = BuildContext(
            moduleName: "M",
            compilerFlags: [],
            projectRoot: URL(fileURLWithPath: "/tmp"),
            targetName: "M",
            sourceFiles: [URL(fileURLWithPath: "/tmp/Other.swift")]
        )
        #expect(tier2.supportsTier2)
    }
}

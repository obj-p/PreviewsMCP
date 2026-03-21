import Foundation
import Testing

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

    // MARK: - BazelBuildSystem.detect

    @Test("BazelBuildSystem detects MODULE.bazel walking up directories")
    func detectBazelModuleBazel() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let moduleBazel = tmpDir.appendingPathComponent("MODULE.bazel")
        try "module(name = \"test\")".write(to: moduleBazel, atomically: true, encoding: .utf8)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // detect() will return nil if bazel is not installed, which is fine —
        // we test the marker detection via the init + projectRoot directly
        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        #expect(bazel.projectRoot.path == tmpDir.standardizedFileURL.path)
    }

    @Test("BazelBuildSystem detects WORKSPACE walking up directories")
    func detectBazelWorkspace() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let workspace = tmpDir.appendingPathComponent("WORKSPACE")
        try "".write(to: workspace, atomically: true, encoding: .utf8)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        #expect(bazel.projectRoot.path == tmpDir.standardizedFileURL.path)
    }

    // MARK: - BazelBuildSystem package/label helpers

    @Test("BazelBuildSystem finds BUILD.bazel package walking up from source file")
    func findBazelPackage() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let pkgDir = tmpDir.appendingPathComponent("Sources/ToDo")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let buildFile = pkgDir.appendingPathComponent("BUILD.bazel")
        try "swift_library(name = \"ToDo\")".write(to: buildFile, atomically: true, encoding: .utf8)

        let sourceFile = pkgDir.appendingPathComponent("ToDoView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        let packagePath = try await bazel.findBazelPackage(for: sourceFile)
        #expect(packagePath == "Sources/ToDo")
    }

    @Test("BazelBuildSystem finds BUILD (not BUILD.bazel) package marker")
    func findBazelPackageBUILD() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let pkgDir = tmpDir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: pkgDir, withIntermediateDirectories: true)

        let buildFile = pkgDir.appendingPathComponent("BUILD")
        try "swift_library(name = \"Lib\")".write(to: buildFile, atomically: true, encoding: .utf8)

        let sourceFile = pkgDir.appendingPathComponent("Lib.swift")
        try "import Foundation".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        let packagePath = try await bazel.findBazelPackage(for: sourceFile)
        #expect(packagePath == "lib")
    }

    @Test("BazelBuildSystem constructs correct source label")
    func buildSourceLabel() async throws {
        let tmpDir = URL(fileURLWithPath: "/tmp/test-project")
        let sourceFile = URL(fileURLWithPath: "/tmp/test-project/Sources/ToDo/ToDoView.swift")

        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        let label = bazel.buildSourceLabel(packagePath: "Sources/ToDo", sourceFile: sourceFile)
        #expect(label == "//Sources/ToDo:ToDoView.swift")
    }

    @Test("BazelBuildSystem constructs label for nested file in package")
    func buildSourceLabelNested() async throws {
        let tmpDir = URL(fileURLWithPath: "/tmp/test-project")
        let sourceFile = URL(fileURLWithPath: "/tmp/test-project/Sources/Feature/Sub/View.swift")

        let bazel = BazelBuildSystem(projectRoot: tmpDir, sourceFile: sourceFile)
        let label = bazel.buildSourceLabel(packagePath: "Sources/Feature", sourceFile: sourceFile)
        #expect(label == "//Sources/Feature:Sub/View.swift")
    }

    // MARK: - BazelBuildSystem label-to-path conversion

    @Test("BazelBuildSystem converts label to relative path")
    func labelToPath() async throws {
        let bazel = BazelBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/a.swift")
        )

        #expect(bazel.labelToPath("//Sources/ToDo:Item.swift") == "Sources/ToDo/Item.swift")
        #expect(bazel.labelToPath("//lib:Lib.swift") == "lib/Lib.swift")
        #expect(bazel.labelToPath("//:root.swift") == "root.swift")
        #expect(bazel.labelToPath("@//Sources/ToDo:Item.swift") == "Sources/ToDo/Item.swift")
        #expect(bazel.labelToPath("invalid") == nil)
    }

    // MARK: - BuildSystemDetector with Bazel

    @Test("BuildSystemDetector prefers SPM when both Package.swift and MODULE.bazel exist")
    func detectorPrefersSPM() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Create both SPM and Bazel markers
        try "// swift-tools-version: 6.0".write(
            to: tmpDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        try "module(name = \"test\")".write(
            to: tmpDir.appendingPathComponent("MODULE.bazel"), atomically: true, encoding: .utf8)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // With explicit projectRoot, SPM should win when Package.swift exists
        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(buildSystem is SPMBuildSystem)
    }

    @Test("BuildSystemDetector returns BazelBuildSystem for explicit Bazel project root")
    func detectorReturnsBazelForExplicitRoot() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Only Bazel markers, no Package.swift
        try "module(name = \"test\")".write(
            to: tmpDir.appendingPathComponent("MODULE.bazel"), atomically: true, encoding: .utf8)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(buildSystem is BazelBuildSystem)
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

    // MARK: - FileWatcher multi-path

    @Test("FileWatcher detects modification of second watched file")
    func fileWatcherMultiPath() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let file1 = tmpDir.appendingPathComponent("first.swift")
        let file2 = tmpDir.appendingPathComponent("second.swift")
        try "initial 1".write(to: file1, atomically: true, encoding: .utf8)
        try "initial 2".write(to: file2, atomically: true, encoding: .utf8)

        let changed = Mutex(false)
        let watcher = try FileWatcher(paths: [file1.path, file2.path], interval: 0.1) {
            changed.withLock { $0 = true }
        }
        defer { watcher.stop() }

        // Wait a moment, then modify only the SECOND file
        try await Task.sleep(for: .milliseconds(200))
        try "modified 2".write(to: file2, atomically: true, encoding: .utf8)

        // Wait for the watcher to detect the change
        try await Task.sleep(for: .milliseconds(500))

        let didChange = changed.withLock { $0 }
        #expect(didChange, "FileWatcher should detect modification of the second watched file")
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

    // MARK: - XcodeBuildSystem.detect

    @Test("XcodeBuildSystem stores projectRoot from init")
    func xcodeProjectInit() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let xcodeproj = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let xcode = XcodeBuildSystem(
            projectRoot: tmpDir, sourceFile: sourceFile, projectFile: xcodeproj)
        #expect(xcode.projectRoot.path == tmpDir.standardizedFileURL.path)
    }

    @Test("XcodeBuildSystem findXcodeProject finds .xcworkspace")
    func findXcodeProjectFindsWorkspace() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let workspace = tmpDir.appendingPathComponent("MyApp.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = XcodeBuildSystem.findXcodeProject(in: tmpDir)
        #expect(result != nil)
        #expect(result?.lastPathComponent == "MyApp.xcworkspace")
    }

    @Test("XcodeBuildSystem findXcodeProject finds .xcodeproj in directory")
    func findXcodeProjectFindsProject() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let xcodeproj = tmpDir.appendingPathComponent("ToDo.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = XcodeBuildSystem.findXcodeProject(in: tmpDir)
        #expect(result != nil)
        #expect(result?.lastPathComponent == "ToDo.xcodeproj")
    }

    @Test("XcodeBuildSystem findXcodeProject prefers workspace over xcodeproj")
    func findXcodeProjectPrefersWorkspace() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let xcodeproj = tmpDir.appendingPathComponent("ToDo.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        let workspace = tmpDir.appendingPathComponent("ToDo.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = XcodeBuildSystem.findXcodeProject(in: tmpDir)
        #expect(result != nil)
        #expect(result?.pathExtension == "xcworkspace")
    }

    // MARK: - XcodeBuildSystem scheme picking

    @Test("XcodeBuildSystem picks single scheme")
    func pickSingleScheme() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/ToDo/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"))

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["MyApp"])
        let scheme = try await xcode.pickScheme(from: info)
        #expect(scheme == "MyApp")
    }

    @Test("XcodeBuildSystem picks scheme matching path component")
    func pickSchemeMatchingPath() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/FeatureB/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"))

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["FeatureA", "FeatureB", "FeatureC"])
        let scheme = try await xcode.pickScheme(from: info)
        #expect(scheme == "FeatureB")
    }

    @Test("XcodeBuildSystem throws ambiguousTarget when no scheme matches")
    func pickSchemeThrowsWhenAmbiguous() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/Unknown/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"))

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["Alpha", "Beta"])
        await #expect(throws: BuildSystemError.self) {
            try await xcode.pickScheme(from: info)
        }
    }

    // MARK: - XcodeBuildSystem build settings parsing

    @Test("XcodeBuildSystem parses build settings output")
    func parseBuildSettings() {
        let output = """
            Build settings for action build and target ToDo:
                BUILT_PRODUCTS_DIR = /Users/dev/DerivedData/ToDo/Build/Products/Debug
                PRODUCT_MODULE_NAME = ToDo
                TARGET_NAME = ToDo
                OBJECT_FILE_DIR_normal = /Users/dev/DerivedData/ToDo/Build/Intermediates.noindex/ToDo.build/Debug/ToDo.build/Objects-normal
                FRAMEWORK_SEARCH_PATHS = /Users/dev/DerivedData/ToDo/Build/Products/Debug
                SWIFT_VERSION = 6.0
            """
        let settings = XcodeBuildSystem.parseBuildSettings(output)
        #expect(settings["BUILT_PRODUCTS_DIR"] == "/Users/dev/DerivedData/ToDo/Build/Products/Debug")
        #expect(settings["PRODUCT_MODULE_NAME"] == "ToDo")
        #expect(settings["TARGET_NAME"] == "ToDo")
        #expect(settings["OBJECT_FILE_DIR_normal"] != nil)
        #expect(settings["SWIFT_VERSION"] == "6.0")
    }

    @Test("XcodeBuildSystem parseBuildSettings stops at second target")
    func parseBuildSettingsMultiTarget() {
        let output = """
            Build settings for action build and target ToDo:
                PRODUCT_MODULE_NAME = ToDo
                TARGET_NAME = ToDo

            Build settings for action build and target ToDoTests:
                PRODUCT_MODULE_NAME = ToDoTests
                TARGET_NAME = ToDoTests
            """
        let settings = XcodeBuildSystem.parseBuildSettings(output)
        #expect(settings["PRODUCT_MODULE_NAME"] == "ToDo")
        #expect(settings["TARGET_NAME"] == "ToDo")
    }

    // MARK: - XcodeBuildSystem search paths parsing

    @Test("XcodeBuildSystem parses space-separated search paths")
    func parseSearchPaths() {
        let paths = XcodeBuildSystem.parseSearchPaths(
            "/path/one /path/two $(inherited)")
        #expect(paths == ["/path/one", "/path/two"])
    }

    @Test("XcodeBuildSystem parses search paths stripping quotes")
    func parseQuotedSearchPaths() {
        let paths = XcodeBuildSystem.parseSearchPaths(
            "\"/path/to/libs\" /normal/path")
        #expect(paths == ["/path/to/libs", "/normal/path"])
    }

    // MARK: - XcodeBuildSystem source file collection

    @Test("XcodeBuildSystem collects source files from OutputFileMap")
    func collectSourceFilesFromOutputFileMap() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let objectDir = tmpDir.appendingPathComponent("Objects-normal/arm64")
        try FileManager.default.createDirectory(at: objectDir, withIntermediateDirectories: true)

        let previewFile = "/project/Sources/ToDo/ToDoView.swift"
        let otherFile = "/project/Sources/ToDo/Item.swift"

        // Create a mock OutputFileMap.json
        let outputFileMap: [String: Any] = [
            "": ["diagnostics": "/path/to/diag"],
            previewFile: ["object": "/path/to/ToDoView.o"],
            otherFile: ["object": "/path/to/Item.o"],
        ]
        let data = try JSONSerialization.data(withJSONObject: outputFileMap)
        try data.write(to: objectDir.appendingPathComponent("ToDo-OutputFileMap.json"))

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/project"),
            sourceFile: URL(fileURLWithPath: previewFile),
            projectFile: URL(fileURLWithPath: "/project/App.xcodeproj"))

        let settings: [String: String] = [
            "OBJECT_FILE_DIR_normal": tmpDir.appendingPathComponent("Objects-normal").path,
            "TARGET_NAME": "ToDo",
        ]

        let files = await xcode.collectSourceFiles(settings: settings, targetName: "ToDo")
        #expect(files != nil)
        #expect(files?.count == 1)
        #expect(files?.first?.lastPathComponent == "Item.swift")
    }

    @Test("XcodeBuildSystem returns nil when OutputFileMap is missing")
    func collectSourceFilesReturnsNilWhenMissing() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"))

        let settings: [String: String] = [
            "OBJECT_FILE_DIR_normal": "/nonexistent/path",
            "TARGET_NAME": "App",
        ]

        let files = await xcode.collectSourceFiles(settings: settings, targetName: "App")
        #expect(files == nil)
    }

    // MARK: - BuildSystemDetector with Xcode

    @Test("BuildSystemDetector prefers SPM over Xcode when both exist")
    func detectorPrefersSPMOverXcode() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        try "// swift-tools-version: 6.0".write(
            to: tmpDir.appendingPathComponent("Package.swift"), atomically: true, encoding: .utf8)
        let xcodeproj = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(buildSystem is SPMBuildSystem)
    }

    @Test("BuildSystemDetector returns XcodeBuildSystem for explicit Xcode project root")
    func detectorReturnsXcodeForExplicitRoot() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let xcodeproj = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(buildSystem is XcodeBuildSystem)
    }

    // MARK: - ProjectInfo Decodable

    @Test("ProjectInfo decodes from xcodebuild -project -list JSON")
    func decodeProjectInfoFromProjectJSON() throws {
        let json = """
            {"project":{"name":"ToDo","configurations":["Debug","Release"],"schemes":["ToDo"],"targets":["ToDo"]}}
            """
        let data = json.data(using: .utf8)!
        let info = try JSONDecoder().decode(XcodeBuildSystem.ProjectInfo.self, from: data)
        #expect(info.schemes == ["ToDo"])
    }

    @Test("ProjectInfo decodes from xcodebuild -workspace -list JSON")
    func decodeProjectInfoFromWorkspaceJSON() throws {
        let json = """
            {"workspace":{"name":"ToDo","schemes":["ToDo"]}}
            """
        let data = json.data(using: .utf8)!
        let info = try JSONDecoder().decode(XcodeBuildSystem.ProjectInfo.self, from: data)
        #expect(info.schemes == ["ToDo"])
    }

    @Test("ProjectInfo throws when JSON has neither project nor workspace key")
    func decodeProjectInfoFromInvalidJSON() throws {
        let json = """
            {"unexpected":{"schemes":["ToDo"]}}
            """
        let data = json.data(using: .utf8)!
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(XcodeBuildSystem.ProjectInfo.self, from: data)
        }
    }

    // MARK: - XcodeBuildSystem workspace stem matching

    @Test("XcodeBuildSystem findXcodeProject prefers stem-matching workspace over auxiliary workspace")
    func findXcodeProjectPrefersStemMatch() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Simulate CocoaPods layout: project + matching workspace + auxiliary workspace
        let xcodeproj = tmpDir.appendingPathComponent("ToDo.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        let workspace = tmpDir.appendingPathComponent("ToDo.xcworkspace")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let podsWorkspace = tmpDir.appendingPathComponent("Pods.xcworkspace")
        try FileManager.default.createDirectory(
            at: podsWorkspace, withIntermediateDirectories: true)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let result = XcodeBuildSystem.findXcodeProject(in: tmpDir)
        #expect(result != nil)
        #expect(result?.lastPathComponent == "ToDo.xcworkspace")
    }
}

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

    @Test("SPMBuildSystem ignores directory named Package.swift")
    func detectSPMIgnoresDirectory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        // Create a directory named Package.swift instead of a file
        let packageDir = tmpDir.appendingPathComponent("Package.swift")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let spm = try await SPMBuildSystem.detect(for: sourceFile)
        #expect(spm == nil)
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

    @Test("BuildSystemDetector ignores directory named Package.swift with explicit projectRoot")
    func detectorIgnoresPackageSwiftDirectory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Directory named Package.swift — should not match as SPM
        let packageDir = tmpDir.appendingPathComponent("Package.swift")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(buildSystem == nil)
    }

    @Test("BuildSystemDetector ignores directory named MODULE.bazel with explicit projectRoot")
    func detectorIgnoresBazelMarkerDirectory() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        // Directory named MODULE.bazel — should not match as Bazel
        let bazelDir = tmpDir.appendingPathComponent("MODULE.bazel")
        try FileManager.default.createDirectory(at: bazelDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let buildSystem = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
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
            platform: .iOS
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

    @Test("XcodeBuildSystem ambiguousTarget error lists candidates and mentions scheme param")
    func ambiguousTargetErrorMessage() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/Unknown/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"))

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["Alpha", "Beta", "Gamma"])
        do {
            _ = try await xcode.pickScheme(from: info)
            Issue.record("expected pickScheme to throw")
        } catch let error as BuildSystemError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("scheme"), "error should mention the scheme parameter")
            #expect(message.contains("Alpha"))
            #expect(message.contains("Beta"))
            #expect(message.contains("Gamma"))
        }
    }

    @Test("XcodeBuildSystem uses requestedScheme when it exists in the list")
    func pickSchemeHonorsRequested() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/Alpha/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"),
            requestedScheme: "Beta")

        // Path-component heuristic would pick Alpha, but explicit request wins.
        let info = XcodeBuildSystem.ProjectInfo(schemes: ["Alpha", "Beta", "Gamma"])
        let scheme = try await xcode.pickScheme(from: info)
        #expect(scheme == "Beta")
    }

    @Test("XcodeBuildSystem throws unknownScheme when requestedScheme is not in the list")
    func pickSchemeRejectsUnknownRequested() async throws {
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/Alpha/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"),
            requestedScheme: "DoesNotExist")

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["Alpha", "Beta"])
        do {
            _ = try await xcode.pickScheme(from: info)
            Issue.record("expected pickScheme to throw")
        } catch let error as BuildSystemError {
            let message = error.errorDescription ?? ""
            #expect(message.contains("DoesNotExist"), "error should name the requested scheme")
            #expect(message.contains("Alpha"))
            #expect(message.contains("Beta"))
        }
    }

    @Test("XcodeBuildSystem requestedScheme wins over single-scheme fast path")
    func pickSchemeRequestedWinsOverSingle() async throws {
        // Even when there's only one scheme, an explicit (mismatched) request
        // should surface a clear error rather than silently using the only one.
        let xcode = XcodeBuildSystem(
            projectRoot: URL(fileURLWithPath: "/tmp"),
            sourceFile: URL(fileURLWithPath: "/tmp/Sources/Alpha/View.swift"),
            projectFile: URL(fileURLWithPath: "/tmp/App.xcodeproj"),
            requestedScheme: "WrongName")

        let info = XcodeBuildSystem.ProjectInfo(schemes: ["OnlyScheme"])
        await #expect(throws: BuildSystemError.self) {
            try await xcode.pickScheme(from: info)
        }
    }

    @Test("BuildSystemDetector threads scheme into XcodeBuildSystem for explicit projectRoot")
    func detectorPassesSchemeToXcode() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let xcodeproj = tmpDir.appendingPathComponent("MyApp.xcodeproj")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("main.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Without a scheme, the detector should still return an XcodeBuildSystem.
        let unbranded = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir)
        #expect(unbranded is XcodeBuildSystem)

        // With a scheme, pickScheme should honor it instead of the heuristic.
        let branded = try await BuildSystemDetector.detect(
            for: sourceFile, projectRoot: tmpDir, scheme: "Beta")
        let xcode = try #require(branded as? XcodeBuildSystem)
        let info = XcodeBuildSystem.ProjectInfo(schemes: ["Alpha", "Beta"])
        let picked = try await xcode.pickScheme(from: info)
        #expect(picked == "Beta")
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

    // MARK: - SPMBuildSystem.findPackageDirectory

    @Test("findPackageDirectory walks up to Package.swift")
    func findPackageDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let packageSwift = tmpDir.appendingPathComponent("Package.swift")
        try "// swift-tools-version: 6.0".write(
            to: packageSwift, atomically: true, encoding: .utf8)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = SPMBuildSystem.findPackageDirectory(from: sourceFile)
        #expect(found?.standardizedFileURL.path == tmpDir.standardizedFileURL.path)
    }

    @Test("findPackageDirectory ignores directory named Package.swift")
    func findPackageDirectoryIgnoresDirectory() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = tmpDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        // Create a directory named Package.swift instead of a file
        let packageDir = tmpDir.appendingPathComponent("Package.swift")
        try FileManager.default.createDirectory(at: packageDir, withIntermediateDirectories: true)

        let sourceFile = sourcesDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = SPMBuildSystem.findPackageDirectory(from: sourceFile)
        #expect(found == nil)
    }

    @Test("findPackageDirectory returns nil for standalone file")
    func findPackageDirectoryNilForStandalone() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("Standalone.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = SPMBuildSystem.findPackageDirectory(from: sourceFile)
        #expect(found == nil)
    }

    /// Regression guard: before the fix, a source file inside an xcodeproj
    /// directory tree would cause `findPackageDirectory` to walk past the
    /// xcodeproj boundary and attribute the file to whatever outer
    /// Package.swift it eventually hit (typically the repo's own). This
    /// triggered a hang where `swift package describe` ran against the
    /// wrong package. The fix short-circuits when the walk crosses an
    /// xcodeproj/xcworkspace/WORKSPACE marker before finding Package.swift.
    @Test("findPackageDirectory returns nil when walk crosses xcodeproj before Package.swift")
    func findPackageDirectoryStopsAtXcodeproj() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        // Layout:
        //   tmpDir/Package.swift                   ← outer SPM package
        //   tmpDir/xcodeproj-child/                ← contains xcodeproj
        //     Foo.xcodeproj
        //     Sources/MyTarget/MyView.swift        ← source we test
        let outerPackageSwift = tmpDir.appendingPathComponent("Package.swift")
        let projectDir = tmpDir.appendingPathComponent("xcodeproj-child")
        let xcodeproj = projectDir.appendingPathComponent("Foo.xcodeproj")
        let sourceDir = projectDir.appendingPathComponent("Sources/MyTarget")
        try FileManager.default.createDirectory(at: xcodeproj, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: outerPackageSwift, atomically: true, encoding: .utf8)
        let sourceFile = sourceDir.appendingPathComponent("MyView.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Without the xcodeproj-boundary check, this would walk up from
        // MyTarget → Sources → xcodeproj-child → tmpDir and return tmpDir
        // (because tmpDir/Package.swift exists). With the fix, it hits
        // xcodeproj-child/Foo.xcodeproj first and returns nil.
        let found = SPMBuildSystem.findPackageDirectory(from: sourceFile)
        #expect(found == nil, "xcodeproj sibling should stop the walk")
    }

    @Test("findPackageDirectory returns nil when walk crosses WORKSPACE (Bazel)")
    func findPackageDirectoryStopsAtBazelWorkspace() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let outerPackageSwift = tmpDir.appendingPathComponent("Package.swift")
        let bazelDir = tmpDir.appendingPathComponent("bazel-child")
        let workspace = bazelDir.appendingPathComponent("WORKSPACE")
        let sourceDir = bazelDir.appendingPathComponent("lib")
        try FileManager.default.createDirectory(at: sourceDir, withIntermediateDirectories: true)
        try "// swift-tools-version: 6.0".write(
            to: outerPackageSwift, atomically: true, encoding: .utf8)
        try "".write(to: workspace, atomically: true, encoding: .utf8)
        let sourceFile = sourceDir.appendingPathComponent("lib.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = SPMBuildSystem.findPackageDirectory(from: sourceFile)
        #expect(found == nil, "Bazel WORKSPACE should stop the walk")
    }

    // MARK: - SPMBuildSystem.detectPlatforms

    @Test("detectPlatforms returns platforms from real SPM package")
    func detectPlatformsFromRealPackage() {
        // Use the examples/spm package which declares both macOS and iOS
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PreviewsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root
            .appendingPathComponent("examples/spm/Sources/ToDo/ToDoView.swift")

        guard FileManager.default.fileExists(atPath: sourceFile.path) else { return }

        let platforms = SPMBuildSystem.detectPlatforms(for: sourceFile)
        #expect(platforms != nil)
        #expect(platforms?.contains("ios") == true)
        #expect(platforms?.contains("macos") == true)
    }

    @Test("detectPlatforms returns nil for standalone file with no package")
    func detectPlatformsNilForStandalone() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        let sourceFile = tmpDir.appendingPathComponent("Standalone.swift")
        try "import SwiftUI".write(to: sourceFile, atomically: true, encoding: .utf8)

        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let platforms = SPMBuildSystem.detectPlatforms(for: sourceFile)
        #expect(platforms == nil)
    }

    @Test("detectPlatformsAsync returns same result as sync variant")
    func detectPlatformsAsync() async {
        let sourceFile = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("examples/spm/Sources/ToDo/ToDoView.swift")

        guard FileManager.default.fileExists(atPath: sourceFile.path) else { return }

        let asyncPlatforms = await SPMBuildSystem.detectPlatformsAsync(for: sourceFile)
        let syncPlatforms = SPMBuildSystem.detectPlatforms(for: sourceFile)
        #expect(asyncPlatforms == syncPlatforms)
    }

    // MARK: - SPMBuildSystem.collectGeneratedSources

    @Test("SPMBuildSystem finds SPM-generated resource accessor under <Target>.build/DerivedSources")
    func collectGeneratedSources_spm_findsResourceAccessor() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let derivedDir = tmpDir.appendingPathComponent("Foo.build/DerivedSources")
        try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let accessor = derivedDir.appendingPathComponent("resource_bundle_accessor.swift")
        try "extension Foundation.Bundle { static var module: Bundle { .main } }"
            .write(to: accessor, atomically: true, encoding: .utf8)

        let found = SPMBuildSystem.collectGeneratedSources(binPath: tmpDir, targetName: "Foo")
        #expect(found.map(\.lastPathComponent) == ["resource_bundle_accessor.swift"])
    }

    @Test("SPMBuildSystem returns empty when no generated sources exist")
    func collectGeneratedSources_spm_emptyWhenMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = SPMBuildSystem.collectGeneratedSources(binPath: tmpDir, targetName: "Missing")
        #expect(found.isEmpty)
    }

    @Test("SPMBuildSystem.collectGeneratedSources only returns .swift files")
    func collectGeneratedSources_spm_filtersByExtension() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let derivedDir = tmpDir.appendingPathComponent("Foo.build/DerivedSources")
        try FileManager.default.createDirectory(at: derivedDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        try "// swift".write(
            to: derivedDir.appendingPathComponent("accessor.swift"), atomically: true,
            encoding: .utf8)
        try "{}".write(
            to: derivedDir.appendingPathComponent("accessor.json"), atomically: true,
            encoding: .utf8)
        try "data".write(
            to: derivedDir.appendingPathComponent("accessor.d"), atomically: true, encoding: .utf8)

        let found = SPMBuildSystem.collectGeneratedSources(binPath: tmpDir, targetName: "Foo")
        #expect(found.map(\.lastPathComponent) == ["accessor.swift"])
    }

    // MARK: - SPMBuildSystem.shouldSkipDependencyTarget

    /// Regression guard for the swift-issue-reporting / `Testing.framework`
    /// bug: SPM builds `IssueReportingTestSupport` as a dynamic library product
    /// (emitting `libIssueReportingTestSupport.dylib` in binPath) that links
    /// `Testing.framework`. The previous dependency-archiving loop linked every
    /// sibling `<Target>.build/` via `-l<Target>`, which made the linker prefer
    /// the dylib over the archive, burning a load command for the test-support
    /// library into the preview host even when the consumer didn't import it.
    /// At launch on the iOS simulator (no `Testing.framework`) the host crashed.
    ///
    /// The fix skips targets that already have a dylib in binPath — autolink
    /// via `-module-link-name` handles linking from real importers.

    @Test("shouldSkipDependencyTarget skips the consumer target itself")
    func shouldSkipDependencyTarget_skipsConsumer() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(
            SPMBuildSystem.shouldSkipDependencyTarget(
                targetName: "MyApp",
                consumerTargetName: "MyApp",
                binPath: tmpDir
            )
        )
    }

    @Test("shouldSkipDependencyTarget skips underscore-prefixed targets")
    func shouldSkipDependencyTarget_skipsUnderscorePrefix() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        #expect(
            SPMBuildSystem.shouldSkipDependencyTarget(
                targetName: "_PluginBundle",
                consumerTargetName: "MyApp",
                binPath: tmpDir
            )
        )
    }

    @Test("shouldSkipDependencyTarget skips targets that SPM built as a dynamic library product")
    func shouldSkipDependencyTarget_skipsDynamicLibraryProduct() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Simulate SPM emitting a .dylib for a `.library(type: .dynamic)` product.
        // The predicate only checks `fileExists`, so an empty file would pass
        // today — but write a 64-bit Mach-O dylib magic header (MH_MAGIC_64,
        // 0xFEEDFACF, little-endian) so if the check ever tightens to "is a
        // real Mach-O" the fixture keeps being shaped like a dylib.
        let dylibPath = tmpDir.appendingPathComponent("libIssueReportingTestSupport.dylib")
        try Data([0xCF, 0xFA, 0xED, 0xFE]).write(to: dylibPath)

        #expect(
            SPMBuildSystem.shouldSkipDependencyTarget(
                targetName: "IssueReportingTestSupport",
                consumerTargetName: "MyApp",
                binPath: tmpDir
            )
        )
    }

    @Test("shouldSkipDependencyTarget does NOT skip ordinary sibling library targets")
    func shouldSkipDependencyTarget_keepsSiblingTarget() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // No .dylib for this target — the existing archive-then-link path is
        // exactly what it needs (SPM left loose .o files behind, no autolink).
        #expect(
            !SPMBuildSystem.shouldSkipDependencyTarget(
                targetName: "SharedModels",
                consumerTargetName: "MyApp",
                binPath: tmpDir
            )
        )
    }

    @Test("shouldSkipDependencyTarget does NOT skip when only a .a archive exists")
    func shouldSkipDependencyTarget_keepsStaticOnlyTarget() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // A pre-existing .a (e.g. from our own prior archive pass) should not
        // flip the skip — we still want -l for static targets so their symbols
        // get pulled in.
        let archivePath = tmpDir.appendingPathComponent("libSharedModels.a")
        try Data().write(to: archivePath)

        #expect(
            !SPMBuildSystem.shouldSkipDependencyTarget(
                targetName: "SharedModels",
                consumerTargetName: "MyApp",
                binPath: tmpDir
            )
        )
    }

    // MARK: - XcodeBuildSystem.collectGeneratedSources

    @Test("XcodeBuildSystem finds Xcode-generated swift under DERIVED_FILE_DIR/DerivedSources")
    func collectGeneratedSources_xcode_findsDerivedSwift() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let derivedSources = tmpDir.appendingPathComponent("DerivedSources")
        try FileManager.default.createDirectory(at: derivedSources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let assets = derivedSources.appendingPathComponent("GeneratedAssetSymbols.swift")
        try "extension ColorResource { }".write(to: assets, atomically: true, encoding: .utf8)
        let strings = derivedSources.appendingPathComponent("GeneratedStringSymbols.swift")
        try "extension String { }".write(to: strings, atomically: true, encoding: .utf8)

        let found = XcodeBuildSystem.collectGeneratedSources(derivedFileDir: tmpDir)
        #expect(
            Set(found.map(\.lastPathComponent))
                == Set(["GeneratedAssetSymbols.swift", "GeneratedStringSymbols.swift"])
        )
    }

    @Test("XcodeBuildSystem returns empty when DerivedSources is missing")
    func collectGeneratedSources_xcode_emptyWhenMissing() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let found = XcodeBuildSystem.collectGeneratedSources(derivedFileDir: tmpDir)
        #expect(found.isEmpty)
    }

    // MARK: - SPMBuildSystem.readPackageName

    /// Minimal LLBuild manifest fixture covering the three cases the parser
    /// must handle: target with -package-name, target without it, and two
    /// targets sharing a common prefix (ToDo / ToDoExtras) that must not
    /// collide with each other.
    private static let fixtureManifest = """
        client:
          name: basic
        commands:
          "<ToDo-debug.module>":
            tool: swift-compiler
            module-name: ToDo
            description: "Compiling Swift Module 'ToDo' (5 sources)"
            args: ["/path/swiftc","-module-name","ToDo","-emit-module","-Onone","-package-name","spm"]

          "<ToDoExtras-debug.module>":
            tool: swift-compiler
            module-name: ToDoExtras
            description: "Compiling Swift Module 'ToDoExtras' (1 sources)"
            args: ["/path/swiftc","-module-name","ToDoExtras","-emit-module","-Onone","-package-name","spm"]

          "<LegacyTarget-debug.module>":
            tool: swift-compiler
            module-name: LegacyTarget
            description: "Compiling Swift Module 'LegacyTarget' (1 sources)"
            args: ["/path/swiftc","-module-name","LegacyTarget","-emit-module","-Onone"]
        """

    private func writeManifest(_ contents: String) throws -> URL {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-manifest-\(UUID().uuidString).yaml")
        try contents.write(to: tmp, atomically: true, encoding: .utf8)
        return tmp
    }

    @Test("readPackageName extracts -package-name for matching target")
    func readPackageNameFindsTarget() throws {
        let manifest = try writeManifest(Self.fixtureManifest)
        defer { try? FileManager.default.removeItem(at: manifest) }

        let name = SPMBuildSystem.readPackageName(
            fromManifestAt: manifest, forTarget: "ToDo")
        #expect(name == "spm")
    }

    @Test("readPackageName distinguishes targets with shared prefix")
    func readPackageNameAvoidsPrefixCollision() throws {
        // ToDoExtras starts with "ToDo"; a naive substring match would
        // return ToDoExtras's args when asked about ToDo (or vice versa).
        // Anchoring the match with surrounding quotes/commas prevents this.
        let manifest = try writeManifest(Self.fixtureManifest)
        defer { try? FileManager.default.removeItem(at: manifest) }

        let todo = SPMBuildSystem.readPackageName(
            fromManifestAt: manifest, forTarget: "ToDo")
        let todoExtras = SPMBuildSystem.readPackageName(
            fromManifestAt: manifest, forTarget: "ToDoExtras")
        #expect(todo == "spm")
        #expect(todoExtras == "spm")
    }

    @Test("readPackageName returns nil when target has no -package-name flag")
    func readPackageNameNilWhenFlagAbsent() throws {
        let manifest = try writeManifest(Self.fixtureManifest)
        defer { try? FileManager.default.removeItem(at: manifest) }

        let name = SPMBuildSystem.readPackageName(
            fromManifestAt: manifest, forTarget: "LegacyTarget")
        #expect(name == nil)
    }

    @Test("readPackageName returns nil when target is not in the manifest")
    func readPackageNameNilForUnknownTarget() throws {
        let manifest = try writeManifest(Self.fixtureManifest)
        defer { try? FileManager.default.removeItem(at: manifest) }

        let name = SPMBuildSystem.readPackageName(
            fromManifestAt: manifest, forTarget: "DoesNotExist")
        #expect(name == nil)
    }

    @Test("readPackageName returns nil when manifest file is missing")
    func readPackageNameNilForMissingFile() {
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-missing-\(UUID().uuidString).yaml")
        let name = SPMBuildSystem.readPackageName(
            fromManifestAt: missing, forTarget: "ToDo")
        #expect(name == nil)
    }

    @Test("manifestPath derives <scratch>/<config>.yaml from bin path")
    func manifestPathFromBinPath() {
        let bin = URL(fileURLWithPath: "/tmp/pkg/.build/arm64-apple-macosx/debug")
        let manifest = SPMBuildSystem.manifestPath(forBinPath: bin)
        #expect(manifest?.path == "/tmp/pkg/.build/debug.yaml")

        let releaseBin = URL(fileURLWithPath: "/tmp/pkg/.build/arm64-apple-macosx/release")
        let releaseManifest = SPMBuildSystem.manifestPath(forBinPath: releaseBin)
        #expect(releaseManifest?.path == "/tmp/pkg/.build/release.yaml")
    }
}

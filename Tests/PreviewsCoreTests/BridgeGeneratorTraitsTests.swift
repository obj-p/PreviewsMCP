import Foundation
import Testing

@testable import PreviewsCore

@Suite("BridgeGenerator Trait Injection")
struct BridgeGeneratorTraitsTests {

    static let testSource = """
        import SwiftUI

        struct TestView: View {
            var body: some View {
                Text("Hello")
            }
        }

        #Preview { TestView() }
        """

    // MARK: - PreviewTraits

    @Test("PreviewTraits.isEmpty returns true when no traits set")
    func traitsIsEmpty() {
        let traits = PreviewTraits()
        #expect(traits.isEmpty)
    }

    @Test("PreviewTraits.isEmpty returns false when colorScheme set")
    func traitsNotEmptyColorScheme() {
        let traits = PreviewTraits(colorScheme: "dark")
        #expect(!traits.isEmpty)
    }

    @Test("PreviewTraits.isEmpty returns false when dynamicTypeSize set")
    func traitsNotEmptyDynamicType() {
        let traits = PreviewTraits(dynamicTypeSize: "large")
        #expect(!traits.isEmpty)
    }

    @Test("PreviewTraits.merged overwrites non-nil values")
    func traitsMerged() {
        let base = PreviewTraits(colorScheme: "light", dynamicTypeSize: "large")
        let overlay = PreviewTraits(colorScheme: "dark")
        let merged = base.merged(with: overlay)
        #expect(merged.colorScheme == "dark")
        #expect(merged.dynamicTypeSize == "large")
    }

    @Test("PreviewTraits.merged preserves base when overlay is nil")
    func traitsMergedPreservesBase() {
        let base = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "accessibility3")
        let overlay = PreviewTraits()
        let merged = base.merged(with: overlay)
        #expect(merged.colorScheme == "dark")
        #expect(merged.dynamicTypeSize == "accessibility3")
    }

    // MARK: - generateCombinedSource

    @Test("generateCombinedSource with no traits produces no modifiers")
    func combinedSourceNoTraits() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()"
        )
        #expect(!source.contains(".preferredColorScheme"))
        #expect(!source.contains(".dynamicTypeSize"))
    }

    @Test("generateCombinedSource with colorScheme injects .preferredColorScheme")
    func combinedSourceColorScheme() {
        let traits = PreviewTraits(colorScheme: "dark")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.dark)"))
        #expect(!source.contains(".dynamicTypeSize"))
    }

    @Test("generateCombinedSource with dynamicTypeSize injects .dynamicTypeSize")
    func combinedSourceDynamicType() {
        let traits = PreviewTraits(dynamicTypeSize: "accessibility3")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".dynamicTypeSize(.accessibility3)"))
        #expect(!source.contains(".preferredColorScheme"))
    }

    @Test("generateCombinedSource with both traits injects both modifiers")
    func combinedSourceBothTraits() {
        let traits = PreviewTraits(colorScheme: "light", dynamicTypeSize: "xxLarge")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.light)"))
        #expect(source.contains(".dynamicTypeSize(.xxLarge)"))
    }

    // MARK: - generateBridgeOnlySource

    @Test("generateBridgeOnlySource with traits injects modifiers")
    func bridgeOnlySourceWithTraits() {
        let traits = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "accessibility1")
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: "ContentView()",
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.dark)"))
        #expect(source.contains(".dynamicTypeSize(.accessibility1)"))
        #expect(source.contains("@_cdecl(\"createPreviewView\")"))
    }

    @Test("generateBridgeOnlySource with no traits produces no modifiers")
    func bridgeOnlySourceNoTraits() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: "ContentView()"
        )
        #expect(!source.contains(".preferredColorScheme"))
        #expect(!source.contains(".dynamicTypeSize"))
    }

    // MARK: - iOS platform

    @Test("generateCombinedSource with traits for iOS includes modifiers")
    func combinedSourceIOSWithTraits() {
        let traits = PreviewTraits(colorScheme: "dark")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            platform: .iOS,
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.dark)"))
        #expect(source.contains("UIHostingController"))
        #expect(!source.contains("NSHostingView"))
    }

    // MARK: - Full compile pipeline with traits

    @Test("Full pipeline with traits compiles successfully")
    func fullPipelineWithTraits() async throws {
        let traits = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "large")
        let previews = PreviewParser.parse(source: Self.testSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: previews[0].closureBody,
            traits: traits
        )

        #expect(combined.contains(".preferredColorScheme(.dark)"))
        #expect(combined.contains(".dynamicTypeSize(.large)"))

        let compiler = try await Compiler()
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "TraitsTest_\(Int.random(in: 0...999999))"
        )

        // Verify dylib exists and is non-empty
        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "Dylib should be non-empty")

        // Verify entry point symbol
        let loader = try DylibLoader(path: result.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
    }

    @Test("PreviewSession.compile with traits produces correct bridge code")
    func previewSessionWithTraits() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("TestView.swift")
        try Self.testSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let traits = PreviewTraits(colorScheme: "dark")
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            compiler: compiler,
            traits: traits
        )

        let compileResult = try await session.compile()
        #expect(FileManager.default.fileExists(atPath: compileResult.dylibPath.path))

        let loader = try DylibLoader(path: compileResult.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
    }

    @Test("PreviewSession.reconfigure updates traits and recompiles")
    func previewSessionReconfigure() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("TestView.swift")
        try Self.testSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            compiler: compiler
        )

        // Initial compile with no traits
        let result1 = try await session.compile()
        let initialTraits = await session.currentTraits
        #expect(initialTraits.isEmpty)

        // Reconfigure with dark mode
        let result2 = try await session.reconfigure(traits: PreviewTraits(colorScheme: "dark"))
        let darkTraits = await session.currentTraits
        #expect(darkTraits.colorScheme == "dark")
        #expect(result2.dylibPath != result1.dylibPath, "Reconfigure should produce a new dylib")

        // Reconfigure with dynamic type (merge: colorScheme should persist)
        let result3 = try await session.reconfigure(
            traits: PreviewTraits(dynamicTypeSize: "accessibility3"))
        let mergedTraits = await session.currentTraits
        #expect(mergedTraits.colorScheme == "dark")
        #expect(mergedTraits.dynamicTypeSize == "accessibility3")
        #expect(result3.dylibPath != result2.dylibPath)
    }

    // MARK: - Multi-preview index selection

    static let multiPreviewSource = """
        import SwiftUI

        struct FirstView: View {
            var body: some View {
                Text("first")
            }
        }

        struct SecondView: View {
            var body: some View {
                Text("second")
            }
        }

        #Preview { FirstView() }

        #Preview("Second") { SecondView() }
        """

    @Test("generateCombinedSource with previewIndex selects correct preview closure body")
    func combinedSourceRespectsPreviewIndex() {
        // Parse to get preview[1]'s closure body
        let previews = PreviewParser.parse(source: Self.multiPreviewSource)
        #expect(previews.count == 2)

        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.multiPreviewSource,
            closureBody: previews[1].closureBody,
            previewIndex: 1
        )

        // The bridge entry point should render SecondView, not FirstView
        // Extract just the @_cdecl function to avoid matching the full source that contains both
        let bridgeRange = source.range(of: "@_cdecl(\"createPreviewView\")")!
        let bridgeCode = String(source[bridgeRange.lowerBound...])

        #expect(bridgeCode.contains("SecondView()"), "Bridge should render SecondView for previewIndex 1")
        #expect(!bridgeCode.contains("FirstView()"), "Bridge should NOT render FirstView for previewIndex 1")
    }

    @Test("generateCombinedSource with default previewIndex selects first preview")
    func combinedSourceDefaultIndex() {
        let previews = PreviewParser.parse(source: Self.multiPreviewSource)
        #expect(previews.count == 2)

        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.multiPreviewSource,
            closureBody: previews[0].closureBody
        )

        let bridgeRange = source.range(of: "@_cdecl(\"createPreviewView\")")!
        let bridgeCode = String(source[bridgeRange.lowerBound...])

        #expect(bridgeCode.contains("FirstView()"), "Bridge should render FirstView for default previewIndex")
        #expect(!bridgeCode.contains("SecondView()"), "Bridge should NOT render SecondView for default previewIndex")
    }

    @Test("generateCombinedSource falls back to closureBody when previewIndex is out of bounds")
    func combinedSourceOutOfBoundsFallback() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.multiPreviewSource,
            closureBody: "FallbackView()",
            previewIndex: 99
        )

        let bridgeRange = source.range(of: "@_cdecl(\"createPreviewView\")")!
        let bridgeCode = String(source[bridgeRange.lowerBound...])

        #expect(bridgeCode.contains("FallbackView()"), "Bridge should fall back to closureBody for out-of-bounds index")
    }

    @Test("generateOverlaySource with previewIndex selects correct preview")
    func overlaySourceRespectsPreviewIndex() {
        let previews = PreviewParser.parse(source: Self.multiPreviewSource)
        #expect(previews.count == 2)

        let (source, _) = BridgeGenerator.generateOverlaySource(
            originalSource: Self.multiPreviewSource,
            closureBody: previews[1].closureBody,
            previewIndex: 1
        )

        let bridgeRange = source.range(of: "@_cdecl(\"createPreviewView\")")!
        let bridgeCode = String(source[bridgeRange.lowerBound...])

        #expect(bridgeCode.contains("SecondView()"), "Overlay bridge should render SecondView for previewIndex 1")
        #expect(!bridgeCode.contains("FirstView()"), "Overlay bridge should NOT render FirstView for previewIndex 1")
    }

    @Test("PreviewSession.compile with previewIndex 1 renders second preview")
    func previewSessionCompilesSecondPreview() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("MultiPreview.swift")
        try Self.multiPreviewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 1,
            compiler: compiler
        )

        let compileResult = try await session.compile()
        #expect(FileManager.default.fileExists(atPath: compileResult.dylibPath.path))

        let loader = try DylibLoader(path: compileResult.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
    }

    // MARK: - switchPreview

    @Test("switchPreview compiles different preview and preserves traits")
    func switchPreviewPreservesTraits() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("MultiPreview.swift")
        try Self.multiPreviewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            compiler: compiler,
            traits: PreviewTraits(colorScheme: "dark")
        )

        let result0 = try await session.compile()
        #expect(FileManager.default.fileExists(atPath: result0.dylibPath.path))

        let result1 = try await session.switchPreview(to: 1)
        #expect(result1.dylibPath != result0.dylibPath)

        let currentIndex = await session.previewIndex
        #expect(currentIndex == 1)

        let traits = await session.currentTraits
        #expect(traits.colorScheme == "dark")
    }

    @Test("switchPreview rolls back previewIndex on invalid index")
    func switchPreviewRollsBack() async throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previews-mcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let sourceFile = tempDir.appendingPathComponent("MultiPreview.swift")
        try Self.multiPreviewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: 0,
            compiler: compiler
        )
        _ = try await session.compile()

        await #expect(throws: PreviewSessionError.self) {
            _ = try await session.switchPreview(to: 99)
        }

        let currentIndex = await session.previewIndex
        #expect(currentIndex == 0, "previewIndex should roll back to 0 after failed switch")

        // Negative index should also fail gracefully
        await #expect(throws: PreviewSessionError.self) {
            _ = try await session.switchPreview(to: -1)
        }
        let afterNegative = await session.previewIndex
        #expect(afterNegative == 0, "previewIndex should roll back after negative index")
    }

    // MARK: - generateOverlaySource

    @Test("generateOverlaySource with traits injects modifiers")
    func overlaySourceWithTraits() {
        let traits = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "xxxLarge")
        let (source, literals) = BridgeGenerator.generateOverlaySource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.dark)"))
        #expect(source.contains(".dynamicTypeSize(.xxxLarge)"))
        #expect(source.contains("DesignTimeStore"))
        #expect(!literals.isEmpty)
    }

    // MARK: - Validation

    @Test("PreviewTraits.validColorSchemes contains exactly light and dark")
    func validColorSchemes() {
        #expect(PreviewTraits.validColorSchemes == ["light", "dark"])
    }

    @Test("PreviewTraits.validDynamicTypeSizes contains all 12 SwiftUI cases")
    func validDynamicTypeSizes() {
        #expect(PreviewTraits.validDynamicTypeSizes.count == 12)
        #expect(PreviewTraits.validDynamicTypeSizes.contains("xSmall"))
        #expect(PreviewTraits.validDynamicTypeSizes.contains("accessibility5"))
        #expect(!PreviewTraits.validDynamicTypeSizes.contains("huge"))
    }

    // MARK: - PreviewTraits.validated()

    @Test("validated accepts valid traits")
    func validatedAcceptsValid() throws {
        let traits = try PreviewTraits.validated(colorScheme: "dark", dynamicTypeSize: "large")
        #expect(traits.colorScheme == "dark")
        #expect(traits.dynamicTypeSize == "large")
    }

    @Test("validated accepts nil traits")
    func validatedAcceptsNil() throws {
        let traits = try PreviewTraits.validated(colorScheme: nil, dynamicTypeSize: nil)
        #expect(traits.isEmpty)
    }

    @Test("validated rejects invalid color scheme")
    func validatedRejectsInvalidColorScheme() {
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(colorScheme: "purple", dynamicTypeSize: nil)
        }
    }

    @Test("validated rejects invalid dynamic type size")
    func validatedRejectsInvalidDynamicTypeSize() {
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(colorScheme: nil, dynamicTypeSize: "huge")
        }
    }

    // MARK: - stableHash determinism

    @Test("stableHash produces deterministic output for known input")
    func stableHashDeterministic() {
        let hash = PreviewSession.stableHash("/Users/test/MyView.swift")
        #expect(hash == PreviewSession.stableHash("/Users/test/MyView.swift"))
        // Different inputs produce different hashes
        #expect(hash != PreviewSession.stableHash("/Users/test/OtherView.swift"))
    }

    @Test("stableHash produces consistent known value")
    func stableHashKnownValue() {
        // Pin a known input/output to detect accidental algorithm changes
        let hash = PreviewSession.stableHash("hello")
        #expect(hash == 0xa430_d846_80aa_bd0b)
    }

    // MARK: - Equatable

    @Test("PreviewTraits Equatable works correctly")
    func traitsEquatable() {
        let a = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "large")
        let b = PreviewTraits(colorScheme: "dark", dynamicTypeSize: "large")
        let c = PreviewTraits(colorScheme: "light")
        #expect(a == b)
        #expect(a != c)
        #expect(PreviewTraits() == PreviewTraits())
    }
}

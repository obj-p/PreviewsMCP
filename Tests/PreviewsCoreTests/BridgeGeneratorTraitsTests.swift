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

    @Test("PreviewTraits.isEmpty returns false when locale set")
    func traitsNotEmptyLocale() {
        let traits = PreviewTraits(locale: "ar")
        #expect(!traits.isEmpty)
    }

    @Test("PreviewTraits.isEmpty returns false when layoutDirection set")
    func traitsNotEmptyLayoutDirection() {
        let traits = PreviewTraits(layoutDirection: "rightToLeft")
        #expect(!traits.isEmpty)
    }

    @Test("PreviewTraits.isEmpty returns false when legibilityWeight set")
    func traitsNotEmptyLegibilityWeight() {
        let traits = PreviewTraits(legibilityWeight: "bold")
        #expect(!traits.isEmpty)
    }

    @Test("PreviewTraits.merged includes new trait fields")
    func traitsMergedNewFields() {
        let base = PreviewTraits(locale: "en", layoutDirection: "leftToRight")
        let overlay = PreviewTraits(locale: "ar", legibilityWeight: "bold")
        let merged = base.merged(with: overlay)
        #expect(merged.locale == "ar")
        #expect(merged.layoutDirection == "leftToRight")
        #expect(merged.legibilityWeight == "bold")
    }

    @Test("PreviewTraits.validated accepts valid new trait values")
    func validatedAcceptsNewTraits() throws {
        let traits = try PreviewTraits.validated(
            locale: "ar", layoutDirection: "rightToLeft", legibilityWeight: "bold"
        )
        #expect(traits.locale == "ar")
        #expect(traits.layoutDirection == "rightToLeft")
        #expect(traits.legibilityWeight == "bold")
    }

    @Test("PreviewTraits.validated rejects locale with injection characters")
    func validatedRejectsLocaleInjection() {
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(locale: "ar\"); import Foundation; //")
        }
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(locale: "en\\nmalicious")
        }
    }

    @Test("PreviewTraits.validated rejects invalid layout direction")
    func validatedRejectsInvalidLayoutDirection() {
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(layoutDirection: "diagonal")
        }
    }

    @Test("PreviewTraits.validated rejects invalid legibility weight")
    func validatedRejectsInvalidLegibilityWeight() {
        #expect(throws: PreviewTraits.ValidationError.self) {
            try PreviewTraits.validated(legibilityWeight: "thin")
        }
    }

    @Test("PreviewTraits.validated accepts any non-empty locale string")
    func validatedAcceptsAnyLocale() throws {
        let traits = try PreviewTraits.validated(locale: "xx-Fake")
        #expect(traits.locale == "xx-Fake")
    }

    @Test("PreviewTraits.validated clears traits on empty string")
    func validatedClearsEmptyString() throws {
        let traits = try PreviewTraits.validated(
            colorScheme: "", dynamicTypeSize: "", locale: "",
            layoutDirection: "", legibilityWeight: ""
        )
        #expect(traits.isEmpty)
    }

    @Test("PreviewTraits.fromPreset resolves rtl, ltr, boldText")
    func fromPresetNewPresets() {
        let rtl = PreviewTraits.fromPreset("rtl")
        #expect(rtl?.layoutDirection == "rightToLeft")

        let ltr = PreviewTraits.fromPreset("ltr")
        #expect(ltr?.layoutDirection == "leftToRight")

        let boldText = PreviewTraits.fromPreset("boldText")
        #expect(boldText?.legibilityWeight == "bold")
    }

    @Test("PreviewTraits.allPresetNames includes new presets")
    func allPresetNamesIncludesNew() {
        let presets = PreviewTraits.allPresetNames
        #expect(presets.contains("rtl"))
        #expect(presets.contains("ltr"))
        #expect(presets.contains("boldText"))
    }

    @Test("parseVariantString parses JSON with new trait fields")
    func parseVariantStringNewFields() throws {
        let variant = try PreviewTraits.parseVariantString(
            "{\"locale\":\"ar\",\"layoutDirection\":\"rightToLeft\",\"label\":\"arabic-rtl\"}"
        )
        #expect(variant.traits.locale == "ar")
        #expect(variant.traits.layoutDirection == "rightToLeft")
        #expect(variant.label == "arabic-rtl")
    }

    @Test("parseVariantString generates default label with new fields")
    func parseVariantStringDefaultLabelNewFields() throws {
        let variant = try PreviewTraits.parseVariantString(
            "{\"locale\":\"ja\",\"legibilityWeight\":\"bold\"}"
        )
        #expect(variant.label == "ja+bold")
    }

    @Test("PreviewTraits Equatable works with new fields")
    func traitsEquatableNewFields() {
        let a = PreviewTraits(locale: "ar", layoutDirection: "rightToLeft", legibilityWeight: "bold")
        let b = PreviewTraits(locale: "ar", layoutDirection: "rightToLeft", legibilityWeight: "bold")
        let c = PreviewTraits(locale: "en")
        #expect(a == b)
        #expect(a != c)
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

    @Test("generateCombinedSource with locale injects .environment locale modifier")
    func combinedSourceLocale() {
        let traits = PreviewTraits(locale: "ar")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".environment(\\.locale, Locale(identifier: \"ar\"))"))
    }

    @Test("generateCombinedSource with layoutDirection injects .environment modifier")
    func combinedSourceLayoutDirection() {
        let traits = PreviewTraits(layoutDirection: "rightToLeft")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".environment(\\.layoutDirection, .rightToLeft)"))
    }

    @Test("generateCombinedSource with legibilityWeight injects .environment modifier")
    func combinedSourceLegibilityWeight() {
        let traits = PreviewTraits(legibilityWeight: "bold")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".environment(\\.legibilityWeight, .bold)"))
    }

    @Test("generateCombinedSource with all 5 traits injects all modifiers")
    func combinedSourceAllFiveTraits() {
        let traits = PreviewTraits(
            colorScheme: "dark", dynamicTypeSize: "large", locale: "ja-JP",
            layoutDirection: "rightToLeft", legibilityWeight: "bold"
        )
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits
        )
        #expect(source.contains(".preferredColorScheme(.dark)"))
        #expect(source.contains(".dynamicTypeSize(.large)"))
        #expect(source.contains(".environment(\\.locale, Locale(identifier: \"ja-JP\"))"))
        #expect(source.contains(".environment(\\.layoutDirection, .rightToLeft)"))
        #expect(source.contains(".environment(\\.legibilityWeight, .bold)"))
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

    // MARK: - Setup plugin code generation

    @Test("generateCombinedSource with setup generates import and previewSetUp entry point")
    func combinedSourceWithSetup() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            setupModule: "MySetup",
            setupType: "AppSetup"
        )
        #expect(source.contains("import MySetup"))
        #expect(source.contains("@_cdecl(\"previewSetUp\")"))
        #expect(source.contains("AppSetup.setUp()"))
        #expect(source.contains("DispatchSemaphore"))
    }

    @Test("generateCombinedSource with setup calls wrap and applies traits outside")
    func combinedSourceSetupWrapAndTraits() {
        let traits = PreviewTraits(colorScheme: "dark")
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            traits: traits,
            setupModule: "MySetup",
            setupType: "AppSetup"
        )
        #expect(source.contains("AppSetup.wrap(innerView)"))
        #expect(source.contains("wrappedView"))
        #expect(source.contains(".preferredColorScheme(.dark)"))

        let wrapIdx = source.range(of: "AppSetup.wrap")!.lowerBound
        let traitIdx = source.range(of: ".preferredColorScheme(.dark)")!.lowerBound
        #expect(wrapIdx < traitIdx, "wrap() should appear before trait modifiers (traits outside wrap)")
    }

    @Test("generateCombinedSource rejects setup with invalid identifier characters")
    func combinedSourceRejectsInvalidSetupIdentifier() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            setupModule: "Foo\n}; /* exploit */",
            setupType: "Bar"
        )
        #expect(!source.contains("previewSetUp"), "Should not generate setup for invalid identifier")
        #expect(!source.contains("exploit"))
    }

    @Test("generateCombinedSource without setup has no previewSetUp or wrap")
    func combinedSourceNoSetup() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()"
        )
        #expect(!source.contains("previewSetUp"))
        #expect(!source.contains(".wrap("))
        #expect(!source.contains("DispatchSemaphore"))
    }

    @Test("generateBridgeOnlySource with setup generates import and entry points")
    func bridgeOnlySourceWithSetup() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: "ContentView()",
            setupModule: "MySetup",
            setupType: "AppSetup"
        )
        #expect(source.contains("import MySetup"))
        #expect(source.contains("@_cdecl(\"previewSetUp\")"))
        #expect(source.contains("AppSetup.setUp()"))
        #expect(source.contains("AppSetup.wrap(innerView)"))
    }

    @Test("generateOverlaySource with setup passes through to combined")
    func overlaySourceWithSetup() {
        let (source, _) = BridgeGenerator.generateOverlaySource(
            originalSource: Self.testSource,
            closureBody: "TestView()",
            setupModule: "MySetup",
            setupType: "AppSetup"
        )
        #expect(source.contains("import MySetup"))
        #expect(source.contains("@_cdecl(\"previewSetUp\")"))
        #expect(source.contains("AppSetup.wrap(innerView)"))
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

    // MARK: - @ViewBuilder nested function

    /// Isolate the bridge `@_cdecl` function from the rest of the combined source
    /// so substring assertions don't accidentally match the original user source.
    private func bridgeSlice(_ source: String) -> String {
        let range = source.range(of: "@_cdecl(\"createPreviewView\")")!
        return String(source[range.lowerBound...])
    }

    static let availablePreviewSource = """
        import SwiftUI

        struct NewView: View {
            var body: some View { Text("new") }
        }

        struct FallbackView: View {
            var body: some View { Text("fallback") }
        }

        #Preview {
            if #available(iOS 16.0, *) {
                NewView()
            } else {
                FallbackView()
            }
        }
        """

    @Test("generateCombinedSource routes if #available body through __PreviewBridge.wrap")
    func combinedSourceWrapsAvailable() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.availablePreviewSource,
            closureBody: """
                if #available(iOS 16.0, *) {
                    NewView()
                } else {
                    FallbackView()
                }
                """
        )
        let bridge = bridgeSlice(source)
        let wrapRange = bridge.range(of: "__PreviewBridge.wrap")
        let ifRange = bridge.range(of: "if #available")
        #expect(wrapRange != nil, "Bridge must call __PreviewBridge.wrap")
        #expect(ifRange != nil)
        #expect(
            wrapRange!.lowerBound < ifRange!.lowerBound,
            "__PreviewBridge.wrap call must appear before the if #available body it contains"
        )
        #expect(
            bridge.contains("SwiftUI.AnyView(__PreviewBridge.wrap"),
            "Bridge must wrap __PreviewBridge.wrap result in SwiftUI.AnyView(...)"
        )
        #expect(
            !bridge.contains("Group {"),
            "Bridge must not use Group (to avoid confusion with Xcode's canvas Group-enumeration)"
        )
        #expect(
            !bridge.contains("__previewBody"),
            "Legacy __previewBody wrapper must not appear in generated bridge"
        )
    }

    @Test("generateBridgeOnlySource routes if #available body through __PreviewBridge.wrap")
    func bridgeOnlySourceWrapsAvailable() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: """
                if #available(iOS 16.0, *) {
                    NewView()
                } else {
                    FallbackView()
                }
                """
        )
        #expect(source.contains("__PreviewBridge.wrap"))
        #expect(source.contains("if #available"))
        #expect(source.contains("SwiftUI.AnyView(__PreviewBridge.wrap"))
    }

    @Test("generateBridgeOnlySource routes if #unavailable body through __PreviewBridge.wrap")
    func bridgeOnlySourceWrapsUnavailable() {
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: """
                if #unavailable(iOS 26.0) {
                    FallbackView()
                } else {
                    NewView()
                }
                """
        )
        #expect(source.contains("__PreviewBridge.wrap"))
        #expect(source.contains("if #unavailable"))
    }

    @Test("generateCombinedSource routes simple bodies through __PreviewBridge.wrap too")
    func combinedSourceWrapsSimpleBody() {
        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: Self.testSource,
            closureBody: "TestView()"
        )
        let bridge = bridgeSlice(source)
        // Simple bodies go through __PreviewBridge.wrap too — dispatch is unconditional
        // so every supported body shape (SwiftUI or UIKit) resolves via overload lookup.
        #expect(bridge.contains("__PreviewBridge.wrap"))
        #expect(bridge.contains("TestView()"))
        #expect(bridge.contains("SwiftUI.AnyView(__PreviewBridge.wrap"))
    }

    @Test("generateCombinedSource routes multi-statement body (leading let) through __PreviewBridge.wrap")
    func combinedSourceWrapsMultiStatement() {
        let multiStmtSource = """
            import SwiftUI

            struct TestView: View {
                let label: String
                var body: some View { Text(label) }
            }

            #Preview {
                let label = "hello"
                TestView(label: label)
            }
            """
        let previews = PreviewParser.parse(source: multiStmtSource)
        #expect(previews.count == 1)

        let (source, _) = BridgeGenerator.generateCombinedSource(
            originalSource: multiStmtSource,
            closureBody: previews[0].closureBody
        )
        let bridge = bridgeSlice(source)
        let wrapRange = bridge.range(of: "__PreviewBridge.wrap")
        let letRange = bridge.range(of: "let label")
        #expect(wrapRange != nil && letRange != nil)
        #expect(
            wrapRange!.lowerBound < letRange!.lowerBound,
            "__PreviewBridge.wrap call must precede the multi-statement body so `let` isn't a bare expression"
        )
    }

    @Test("if #available body with traits applies modifiers on the __PreviewBridge.wrap call")
    func availableBodyWithTraits() {
        let traits = PreviewTraits(colorScheme: "dark")
        let source = BridgeGenerator.generateBridgeOnlySource(
            moduleName: "MyTarget",
            closureBody: """
                if #available(iOS 16.0, *) {
                    NewView()
                } else {
                    FallbackView()
                }
                """,
            traits: traits
        )
        #expect(source.contains("__PreviewBridge.wrap"))
        #expect(source.contains(".preferredColorScheme(.dark)"))
        // The modifier must be chained onto the wrap() result, inside SwiftUI.AnyView(...).
        #expect(
            source.contains("SwiftUI.AnyView(__PreviewBridge.wrap"),
            "Bridge must wrap __PreviewBridge.wrap result in SwiftUI.AnyView(...)"
        )
        // The closure body's closing `}` must come before the modifier — i.e. the modifier
        // chains on the wrap() call's result, not on something inside the body.
        let closingBraceRange = source.range(of: "}\n            .preferredColorScheme(.dark)")
        #expect(
            closingBraceRange != nil,
            "Modifier must be applied to the __PreviewBridge.wrap { ... } result, not inside its body"
        )
    }

    @Test("Full pipeline with if #available body compiles successfully")
    func fullPipelineWithIfAvailable() async throws {
        let availableSource = """
            import SwiftUI

            struct NewView: View {
                var body: some View { Text("new") }
            }

            struct FallbackView: View {
                var body: some View { Text("fallback") }
            }

            #Preview {
                if #available(macOS 14.0, iOS 17.0, *) {
                    NewView()
                } else {
                    FallbackView()
                }
            }
            """

        let previews = PreviewParser.parse(source: availableSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: availableSource,
            closureBody: previews[0].closureBody
        )

        let compiler = try await Compiler()
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "AvailTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "Dylib should be non-empty")

        let loader = try DylibLoader(path: result.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
    }

    @Test("Full pipeline with multi-statement body compiles successfully")
    func fullPipelineWithMultiStatement() async throws {
        let multiSource = """
            import SwiftUI

            struct TestView: View {
                let label: String
                var body: some View { Text(label) }
            }

            #Preview {
                let label = "hello"
                TestView(label: label)
            }
            """

        let previews = PreviewParser.parse(source: multiSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: multiSource,
            closureBody: previews[0].closureBody
        )

        let compiler = try await Compiler()
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "MultiStmtTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "Dylib should be non-empty")
    }

    // MARK: - UIKit body compile pipeline (iOS)

    @Test("Full pipeline with UIView body compiles for iOS")
    func fullPipelineUIViewBody() async throws {
        let uiViewSource = """
            import SwiftUI
            import UIKit

            final class ExampleUIView: UIView {
                init() {
                    super.init(frame: .zero)
                    backgroundColor = .systemRed
                }
                required init?(coder: NSCoder) { fatalError() }
            }

            #Preview { ExampleUIView() }
            """

        let previews = PreviewParser.parse(source: uiViewSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: uiViewSource,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )
        #expect(combined.contains("__PreviewBridge.wrap"))
        #expect(combined.contains("UIViewRepresentable"))

        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "UIViewTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "iOS dylib with UIView body should be non-empty")
    }

    @Test("Full pipeline with parameterized UIView init compiles for iOS")
    func fullPipelineUIViewWithInitArgs() async throws {
        // Mirrors the reported failure form: `#Preview { ExampleUIView(deps: deps) }`
        // wrapped inside a helper closure (here: a trivial `make(...)` instead of
        // `withDependencies`, which would require pulling in swift-dependencies).
        let uiViewSource = """
            import SwiftUI
            import UIKit

            final class ExampleUIView: UIView {
                init(label: String) {
                    super.init(frame: .zero)
                    backgroundColor = .systemGreen
                    accessibilityLabel = label
                }
                required init?(coder: NSCoder) { fatalError() }
            }

            func make<T>(_ build: () -> T) -> T { build() }

            #Preview { make { ExampleUIView(label: "hi") } }
            """

        let previews = PreviewParser.parse(source: uiViewSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: uiViewSource,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )

        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "UIViewInitArgsTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "iOS dylib with parameterized UIView init should be non-empty")
    }

    @Test("Full pipeline with UIViewController body compiles for iOS")
    func fullPipelineUIViewControllerBody() async throws {
        let vcSource = """
            import SwiftUI
            import UIKit

            final class ExampleVC: UIViewController {
                override func viewDidLoad() {
                    super.viewDidLoad()
                    view.backgroundColor = .systemBlue
                }
            }

            #Preview { ExampleVC() }
            """

        let previews = PreviewParser.parse(source: vcSource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: vcSource,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )
        #expect(combined.contains("__PreviewBridge.wrap"))
        #expect(combined.contains("UIViewControllerRepresentable"))

        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "UIVCTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "iOS dylib with UIViewController body should be non-empty")
    }

    @Test("Full pipeline with SwiftUI body on iOS still compiles (regression guard)")
    func fullPipelineSwiftUIBodyIOS() async throws {
        let swiftUISource = """
            import SwiftUI

            struct IOSView: View {
                var body: some View { Text("ios") }
            }

            #Preview { IOSView() }
            """

        let previews = PreviewParser.parse(source: swiftUISource)
        #expect(previews.count == 1)

        let (combined, _) = BridgeGenerator.generateCombinedSource(
            originalSource: swiftUISource,
            closureBody: previews[0].closureBody,
            platform: .iOS
        )

        let compiler = try await Compiler(platform: .iOS)
        let result = try await compiler.compileCombined(
            source: combined,
            moduleName: "SwiftUIiOSTest_\(Int.random(in: 0...999999))"
        )

        let attrs = try FileManager.default.attributesOfItem(atPath: result.dylibPath.path)
        let size = attrs[.size] as? Int ?? 0
        #expect(size > 0, "iOS dylib with SwiftUI body should still be non-empty")
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

import Foundation
import Testing

@testable import PreviewsCore

@Suite("BridgeGenerator iOS render entry")
struct BridgeGeneratorIOSRenderTests {
    static let source = """
        import SwiftUI

        struct TestView: View {
            var body: some View {
                Text("Hello")
            }
        }

        #Preview { TestView() }
        """

    @Test("iOS JIT source emits a renderPreviewToFile entry that hosts the view on the key window")
    func iosEmitsRenderEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            platform: .iOS,
            renderOutputPath: "/tmp/out.png",
            designTimeValuesPath: "/tmp/out.json")
        #expect(generated.source.contains("@_cdecl(\"renderPreviewToFile\")"))
        #expect(generated.source.contains("UIHostingController(rootView: view)"))
        #expect(generated.source.contains("rootViewController"))
        #expect(generated.source.contains("MainActor.assumeIsolated"))
        #expect(generated.source.contains("isKeyWindow"))
        #expect(!generated.source.contains("NSHostingView"))
        #expect(!generated.source.contains("NSWindow"))
    }

    @Test("iOS render entry re-seeds DesignTimeStore from the values JSON")
    func iosRenderEntrySeedsValues() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            platform: .iOS,
            renderOutputPath: "/tmp/out.png",
            designTimeValuesPath: "/tmp/out.json")
        #expect(generated.source.contains("DesignTimeStore.shared.values = __dtValues"))
    }

    @Test("iOS source without a render path emits no render entry (dylib path)")
    func iosWithoutRenderPathHasNoEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            platform: .iOS)
        #expect(!generated.source.contains("renderPreviewToFile"))
    }
}

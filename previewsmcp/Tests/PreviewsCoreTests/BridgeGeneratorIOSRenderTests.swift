import Foundation
@testable import PreviewsCore
import Testing

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

    @Test("iOS JIT source emits a renderPreviewToFile entry that installs the view via previewsmcp_set_preview_vc")
    func iosEmitsRenderEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            platform: .iOS,
            renderOutputPath: "/tmp/out.png",
            designTimeValuesPath: "/tmp/out.json"
        )
        #expect(generated.source.contains("@_cdecl(\"renderPreviewToFile\")"))
        #expect(generated.source.contains("UIHostingController(rootView: view)"))
        #expect(generated.source.contains("previewsmcp_set_preview_vc"))
        #expect(generated.source.contains("MainActor.assumeIsolated"))
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
            designTimeValuesPath: "/tmp/out.json"
        )
        #expect(generated.source.contains("DesignTimeStore.shared.values = __dtValues"))
    }

    @Test("iOS source without a render path emits no render entry (dylib path)")
    func iosWithoutRenderPathHasNoEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            platform: .iOS
        )
        #expect(!generated.source.contains("renderPreviewToFile"))
    }
}

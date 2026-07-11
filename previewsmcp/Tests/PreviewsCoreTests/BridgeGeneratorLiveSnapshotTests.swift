import Foundation
@testable import PreviewsCore
import Testing

@Suite("BridgeGenerator live snapshot entry")
struct BridgeGeneratorLiveSnapshotTests {
    static let source = """
    import SwiftUI

    struct TestView: View {
        var body: some View {
            Text("Hello")
        }
    }

    #Preview { TestView() }
    """

    @Test("visible render window emits a snapshotPreviewWindow entry baked with the image path")
    func visibleEmitsSnapshotEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: false
            ),
            frameSidecarPath: "/tmp/frame.json"
        )
        #expect(generated.source.contains("@_cdecl(\"snapshotPreviewWindow\")"))
        #expect(generated.source.contains("/tmp/out.png"))
    }

    @Test("headless render window emits no snapshotPreviewWindow entry")
    func headlessEmitsNoSnapshotEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: true
            ),
            frameSidecarPath: "/tmp/frame.json"
        )
        #expect(!generated.source.contains("snapshotPreviewWindow"))
    }

    @Test("no render window emits no snapshotPreviewWindow entry")
    func noWindowEmitsNoSnapshotEntry() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: nil,
            frameSidecarPath: nil
        )
        #expect(!generated.source.contains("snapshotPreviewWindow"))
    }
}

import Foundation
@testable import PreviewsCore
import Testing

@Suite("BridgeGenerator frame handover")
struct BridgeGeneratorFrameHandoverTests {
    static let source = """
    import SwiftUI

    struct TestView: View {
        var body: some View {
            Text("Hello")
        }
    }

    #Preview { TestView() }
    """

    @Test("visible render window installs move/resize observers that write the frame sidecar")
    func visibleInstallsFrameObservers() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: false
            ),
            frameSidecarPath: "/tmp/frame.json"
        )
        #expect(generated.source.contains("didMoveNotification"))
        #expect(generated.source.contains("didResizeNotification"))
        #expect(generated.source.contains("didBecomeKeyNotification"))
        #expect(generated.source.contains("didResignKeyNotification"))
        #expect(generated.source.contains("/tmp/frame.json"))
        #expect(generated.source.contains("recordPreviewWindowState"))
        #expect(generated.source.contains("makeKeyAndOrderFront"))
        #expect(generated.source.contains("orderFrontRegardless"))
        #expect(generated.source.contains("displayIfNeeded"))
    }

    @Test("headless render window installs no frame observers")
    func headlessInstallsNoFrameObservers() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: true
            ),
            frameSidecarPath: "/tmp/frame.json"
        )
        #expect(!generated.source.contains("didMoveNotification"))
        #expect(!generated.source.contains("didResizeNotification"))
        #expect(!generated.source.contains("recordPreviewWindowState"))
        #expect(!generated.source.contains("makeKeyAndOrderFront"))
    }
}

import Foundation
@testable import PreviewsCore
import Testing

@Suite("BridgeGenerator render size")
struct BridgeGeneratorRenderSizeTests {
    static let source = """
    import SwiftUI

    struct TestView: View {
        var body: some View {
            Text("Hello")
        }
    }

    #Preview { TestView() }
    """

    @Test("headless render window renders at the session size, off-screen, without activating")
    func headlessUsesSessionSizeOffScreen() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: true
            )
        )
        #expect(generated.source.contains("width: 800.0, height: 1000.0"))
        #expect(!generated.source.contains("width: 400, height: 600"))
        #expect(generated.source.contains(".borderless"))
        #expect(generated.source.contains("-10_000"))
        #expect(!generated.source.contains("makeKeyAndOrderFront"))
    }

    @Test("visible render window renders at the session size in a titled key window")
    func visibleUsesSessionSizeTitled() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", headless: false
            )
        )
        #expect(generated.source.contains("width: 800.0, height: 1000.0"))
        #expect(generated.source.contains(".titled"))
        #expect(generated.source.contains("makeKeyAndOrderFront"))
    }

    @Test("non-activating visible window presents titled without taking key or activating")
    func nonActivatingVisiblePresentsWithoutFocus() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: Self.source,
            closureBody: "TestView()",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 800, height: 1000, title: "t", activates: false
            ),
            frameSidecarPath: "/tmp/frame.json"
        )
        #expect(generated.source.contains(".titled"))
        // Two presents: the window-reuse path and the new-window path. One means the
        // new-window branch lost its present call and a fresh window never shows.
        let presents = generated.source.components(separatedBy: "orderFrontRegardless").count - 1
        #expect(presents == 2)
        #expect(!generated.source.contains("makeKeyAndOrderFront"))
        #expect(!generated.source.contains("activate(ignoringOtherApps"))
        #expect(generated.source.contains("didMoveNotification"))
        #expect(generated.source.contains("__previewsmcpWriteWindowState"))
    }
}

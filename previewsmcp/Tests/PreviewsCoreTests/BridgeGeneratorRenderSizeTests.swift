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
}

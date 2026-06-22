import Foundation
import Testing

@testable import PreviewsCore

@Suite("BridgeGenerator setup and escaping guards")
struct BridgeGeneratorSetupGuardTests {

    @Test("isUsableSetup rejects non-identifier module or type names")
    func isUsableSetupValidation() {
        #expect(BridgeGenerator.isUsableSetup(module: "MySetup", type: "MySetup"))
        #expect(BridgeGenerator.isUsableSetup(module: "My.Setup", type: "MySetup"))
        #expect(!BridgeGenerator.isUsableSetup(module: nil, type: "MySetup"))
        #expect(!BridgeGenerator.isUsableSetup(module: "MySetup", type: nil))
        #expect(!BridgeGenerator.isUsableSetup(module: "My-Setup", type: "MySetup"))
        #expect(!BridgeGenerator.isUsableSetup(module: "MySetup", type: "My Setup"))
    }

    @Test("escapedForSwiftStringLiteral neutralizes quotes, backslashes, and control characters")
    func stringLiteralEscaping() {
        #expect(BridgeGenerator.escapedForSwiftStringLiteral(#"a"b"#) == #"a\"b"#)
        #expect(BridgeGenerator.escapedForSwiftStringLiteral(#"a\b"#) == #"a\\b"#)
        #expect(BridgeGenerator.escapedForSwiftStringLiteral("a\nb") == #"a\u{a}b"#)
        #expect(BridgeGenerator.escapedForSwiftStringLiteral("a\tb") == #"a\u{9}b"#)
        #expect(BridgeGenerator.escapedForSwiftStringLiteral("plain.swift") == "plain.swift")
    }

    @Test("render entry with a newline-bearing title still generates compilable source text")
    func titleWithNewlineGeneratesSingleLineLiteral() {
        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: "import SwiftUI\n\n#Preview { Text(\"hi\") }",
            closureBody: "Text(\"hi\")",
            renderOutputPath: "/tmp/out.png",
            renderWindow: JITRenderWindow(
                x: 0, y: 0, width: 100, height: 100, title: "Preview: a\nb.swift")
        )
        #expect(generated.source.contains(#"created.title = "Preview: a\u{a}b.swift""#))
    }
}

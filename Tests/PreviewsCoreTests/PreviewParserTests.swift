import Testing

@testable import PreviewsCore

@Suite("PreviewParser")
struct PreviewParserTests {

    @Test("Finds a single unnamed preview")
    func singleUnnamedPreview() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            #Preview {
                MyView()
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].name == nil)
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[0].index == 0)
    }

    @Test("Finds a named preview")
    func namedPreview() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            #Preview("Dark Mode") {
                MyView()
                    .preferredColorScheme(.dark)
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].name == "Dark Mode")
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[0].closureBody.contains(".preferredColorScheme(.dark)"))
    }

    @Test("Finds multiple previews in one file")
    func multiplePreviews() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            #Preview {
                MyView()
            }

            #Preview("Dark Mode") {
                MyView()
                    .preferredColorScheme(.dark)
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 2)
        #expect(previews[0].name == nil)
        #expect(previews[0].index == 0)
        #expect(previews[1].name == "Dark Mode")
        #expect(previews[1].index == 1)
    }

    // MARK: - Snippet

    @Test("Snippet returns first line of multi-line closure body")
    func snippetMultiLine() {
        let source = """
            import SwiftUI
            struct V: View { var body: some View { Text("Hi") } }
            #Preview {
                V()
                    .padding()
            }
            """
        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].snippet == "V()")
    }

    @Test("Snippet returns single-line closure body as-is")
    func snippetSingleLine() {
        let source = """
            import SwiftUI
            struct V: View { var body: some View { Text("Hi") } }
            #Preview { V() }
            """
        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].snippet == "V()")
    }

    @Test("Snippet truncates lines longer than 80 characters")
    func snippetTruncation() {
        let longExpr =
            "SomeVeryLongViewName(parameter1: \"value1\", parameter2: \"value2\", parameter3: \"value3\", parameter4: true)"
        let source = """
            import SwiftUI
            struct V: View { var body: some View { Text("Hi") } }
            #Preview {
                \(longExpr)
            }
            """
        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].snippet.count <= 80)
        #expect(previews[0].snippet.hasSuffix("..."))
    }

    @Test("Returns empty for file with no previews")
    func noPreviews() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.isEmpty)
    }
}

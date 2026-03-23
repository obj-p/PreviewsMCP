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

    // MARK: - PreviewProvider

    @Test("Finds a basic PreviewProvider with single view")
    func basicPreviewProvider() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    MyView()
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[0].index == 0)
    }

    @Test("PreviewProvider with Group splits into multiple previews")
    func previewProviderGroup() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    Group {
                        MyView()
                        MyView()
                            .preferredColorScheme(.dark)
                        MyView()
                            .environment(\\.sizeCategory, .accessibilityExtraLarge)
                    }
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 3)
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[1].closureBody.contains(".preferredColorScheme(.dark)"))
        #expect(previews[2].closureBody.contains(".accessibilityExtraLarge"))
        #expect(previews[0].index == 0)
        #expect(previews[1].index == 1)
        #expect(previews[2].index == 2)
    }

    @Test("PreviewProvider with bare multi-statement body (implicit @ViewBuilder)")
    func previewProviderMultiStatement() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    MyView()
                    MyView()
                        .preferredColorScheme(.dark)
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 2)
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[1].closureBody.contains(".preferredColorScheme(.dark)"))
    }

    @Test("PreviewProvider extracts .previewDisplayName as name")
    func previewProviderDisplayName() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    Group {
                        MyView()
                            .previewDisplayName("Default")
                        MyView()
                            .preferredColorScheme(.dark)
                            .previewDisplayName("Dark Mode")
                    }
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 2)
        #expect(previews[0].name == "Default")
        #expect(previews[1].name == "Dark Mode")
    }

    @Test("PreviewProvider and #Preview in same file merge with sequential indices")
    func previewProviderAndMacroMixed() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            #Preview("Macro Preview") {
                MyView()
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    MyView()
                        .preferredColorScheme(.dark)
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 2)
        #expect(previews[0].name == "Macro Preview")
        #expect(previews[0].index == 0)
        #expect(previews[1].index == 1)
        #expect(previews[1].closureBody.contains(".preferredColorScheme(.dark)"))
    }

    @Test("Struct conforming to PreviewProvider with no previews var yields nothing")
    func previewProviderNoPreviews() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var something: some View {
                    MyView()
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.isEmpty)
    }

    @Test("PreviewProvider with return statement unwraps correctly")
    func previewProviderWithReturn() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    return Group {
                        MyView()
                        MyView()
                            .preferredColorScheme(.dark)
                    }
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 2)
        #expect(previews[0].closureBody.contains("MyView()"))
        #expect(previews[1].closureBody.contains(".preferredColorScheme(.dark)"))
    }

    @Test("PreviewProvider with ForEach is treated as single preview")
    func previewProviderForEach() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    ForEach(["iPhone 14", "iPhone SE"], id: \\.self) { device in
                        MyView()
                            .previewDevice(PreviewDevice(rawValue: device))
                    }
                }
            }
            """

        let previews = PreviewParser.parse(source: source)
        #expect(previews.count == 1)
        #expect(previews[0].closureBody.contains("ForEach"))
    }

    @Test("PreviewProvider with literals round-trips through ThunkGenerator")
    func previewProviderThunkRoundTrip() {
        let source = """
            import SwiftUI

            struct MyView: View {
                var body: some View { Text("Hello") }
            }

            struct MyView_Previews: PreviewProvider {
                static var previews: some View {
                    MyView()
                }
            }
            """

        // Parse, transform with ThunkGenerator, re-parse — should still find the preview
        let firstParse = PreviewParser.parse(source: source)
        #expect(firstParse.count == 1)

        let transformed = ThunkGenerator.transform(source: source)
        let secondParse = PreviewParser.parse(source: transformed.source)
        #expect(secondParse.count == 1)
        #expect(secondParse[0].closureBody.contains("MyView()"))
    }
}

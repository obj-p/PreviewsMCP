import SwiftParser
import SwiftSyntax
import Testing

@testable import PreviewsCore

/// Direct unit tests for `LiteralRegionClassifier.classify(_:)`. The classifier
/// is also exercised transitively via `ThunkGeneratorTests` (which checks the
/// region field on collected `LiteralEntry` values) and `LiteralDifferTests`
/// (which checks that tainted literals downgrade `.literalOnly` to `.structural`).
/// These tests target the public seam directly so a future change can verify
/// the classifier in isolation without reaching through the thunk pipeline.
@Suite("LiteralRegionClassifier")
struct LiteralRegionClassifierTests {

    /// Find the first string-literal expression matching `value` in `source`
    /// and return the classifier's verdict on it. Mirrors how
    /// `LiteralCollector` invokes the classifier — pass the literal node, not
    /// its parent — so the tests exercise the same call shape as production.
    private func regionOfFirstString(_ value: String, in source: String) -> LiteralRegion? {
        let tree = Parser.parse(source: source)
        let finder = StringLiteralFinder(target: value, viewMode: .sourceAccurate)
        finder.walk(tree)
        guard let node = finder.match else { return nil }
        return LiteralRegionClassifier.classify(node)
    }

    @Test("Literal with no UIKit-typed enclosing scope is .swiftUI")
    func bareSwiftUIRegion() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hi") }
            }
            """
        #expect(regionOfFirstString("Hi", in: source) == .swiftUI)
    }

    @Test("Literal inside class extending UIView is .uiKit")
    func uiViewSubclassRegion() {
        let source = """
            import UIKit
            class MyView: UIView {
                func setup() {
                    let l = UILabel()
                    l.text = "before"
                }
            }
            """
        #expect(regionOfFirstString("before", in: source) == .uiKit)
    }

    @Test("Literal inside UIViewRepresentable conformance is .uiKit")
    func uiViewRepresentableRegion() {
        let source = """
            import SwiftUI
            import UIKit
            struct W: UIViewRepresentable {
                func makeUIView(context: Context) -> UIView {
                    let v = UIView()
                    v.accessibilityLabel = "tag"
                    return v
                }
                func updateUIView(_ uiView: UIView, context: Context) {}
            }
            """
        #expect(regionOfFirstString("tag", in: source) == .uiKit)
    }

    @Test("Literal inside func returning UIView is .uiKit")
    func functionReturningUIViewRegion() {
        let source = """
            import UIKit
            func makeLabel() -> UILabel {
                let l = UILabel()
                l.text = "hi"
                return l
            }
            """
        #expect(regionOfFirstString("hi", in: source) == .uiKit)
    }

    @Test("Literal inside extension on UIView is .uiKit")
    func uiViewExtensionRegion() {
        let source = """
            import UIKit
            extension UIView {
                func helper() {
                    let l = UILabel()
                    l.text = "tag"
                }
            }
            """
        #expect(regionOfFirstString("tag", in: source) == .uiKit)
    }

    @Test("Literal inside identifier merely embedding UIView is .swiftUI")
    func wordBoundaryFalsePositiveGuard() {
        // `MyUIViewSubclass` and `UIViewable` happen to contain "UIView" as a
        // substring. The word-boundary check must not taint them.
        let source = """
            struct MyUIViewSubclass {
                func make() -> String { "shouldFastPath" }
            }
            protocol UIViewable {
                func tag() -> String
            }
            extension UIViewable {
                func tag() -> String { "tagVal" }
            }
            """
        #expect(regionOfFirstString("shouldFastPath", in: source) == .swiftUI)
        #expect(regionOfFirstString("tagVal", in: source) == .swiftUI)
    }
}

/// Walks a syntax tree to find a `StringLiteralExprSyntax` whose joined
/// content matches `target`. Used by the classifier tests to obtain a real
/// literal node to pass into `LiteralRegionClassifier.classify(_:)`.
private final class StringLiteralFinder: SyntaxVisitor {
    let target: String
    var match: StringLiteralExprSyntax?

    init(target: String, viewMode: SyntaxTreeViewMode) {
        self.target = target
        super.init(viewMode: viewMode)
    }

    override func visit(_ node: StringLiteralExprSyntax) -> SyntaxVisitorContinueKind {
        guard match == nil else { return .skipChildren }
        let text = node.segments.compactMap { segment -> String? in
            if case .stringSegment(let s) = segment { return s.content.text }
            return nil
        }.joined()
        if text == target {
            match = node
            return .skipChildren
        }
        return .visitChildren
    }
}

import Testing

@testable import PreviewsCore

@Suite("LiteralDiffer")
struct LiteralDifferTests {

    @Test("Detects literal-only string change")
    func literalOnlyStringChange() {
        let old = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hello") }
            }
            """
        let new = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("World") }
            }
            """
        let result = LiteralDiffer.diff(old: old, new: new)
        guard case .literalOnly(let changes) = result else {
            Issue.record("Expected .literalOnly, got .structural")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].id == "#0")
        #expect(changes[0].newValue == .string("World"))
    }

    @Test("Detects literal-only integer change")
    func literalOnlyIntegerChange() {
        let old = """
            import SwiftUI
            struct V: View {
                var body: some View { VStack(spacing: 20) { Text("Hi") } }
            }
            """
        let new = """
            import SwiftUI
            struct V: View {
                var body: some View { VStack(spacing: 30) { Text("Hi") } }
            }
            """
        let result = LiteralDiffer.diff(old: old, new: new)
        guard case .literalOnly(let changes) = result else {
            Issue.record("Expected .literalOnly, got .structural")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].newValue == .integer(30))
    }

    @Test("Detects structural change — added code")
    func structuralAddedCode() {
        let old = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hello") }
            }
            """
        let new = """
            import SwiftUI
            struct V: View {
                var body: some View { VStack { Text("Hello") } }
            }
            """
        let result = LiteralDiffer.diff(old: old, new: new)
        guard case .structural = result else {
            Issue.record("Expected .structural")
            return
        }
    }

    @Test("Detects structural change — removed code")
    func structuralRemovedCode() {
        let old = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    VStack {
                        Text("Hello")
                        Text("World")
                    }
                }
            }
            """
        let new = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    VStack {
                        Text("Hello")
                    }
                }
            }
            """
        let result = LiteralDiffer.diff(old: old, new: new)
        guard case .structural = result else {
            Issue.record("Expected .structural")
            return
        }
    }

    @Test("No changes returns empty literal-only")
    func noChanges() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hello") }
            }
            """
        let result = LiteralDiffer.diff(old: source, new: source)
        guard case .literalOnly(let changes) = result else {
            Issue.record("Expected .literalOnly, got .structural")
            return
        }
        #expect(changes.isEmpty)
    }

    @Test("Multiple simultaneous literal changes")
    func multipleLiteralChanges() {
        let old = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    VStack(spacing: 20) {
                        Text("Hello")
                        Text("World")
                    }
                }
            }
            """
        let new = """
            import SwiftUI
            struct V: View {
                var body: some View {
                    VStack(spacing: 30) {
                        Text("Bye")
                        Text("Earth")
                    }
                }
            }
            """
        let result = LiteralDiffer.diff(old: old, new: new)
        guard case .literalOnly(let changes) = result else {
            Issue.record("Expected .literalOnly, got .structural")
            return
        }
        #expect(changes.count == 3)  // spacing + two strings
    }

    // MARK: - UIKit-region taint (#160)
    //
    // The literal-only fast path applies the new value to DesignTimeStore but
    // relies on @Observable to drive a re-render. UIKit captures the value once
    // at construction, so a literal edit inside a UIKit-evaluated scope silently
    // no-ops on the fast path. The differ taints these edits as `.structural`
    // so the daemon force-reloads instead.

    @Test("UIKit class context — string change forces structural")
    func uikitClassContextForcesStructural() {
        let old = """
            import SwiftUI
            import UIKit
            class MyView: UIView {
                func setup() {
                    let label = UILabel()
                    label.text = "before"
                }
            }
            #Preview { Text("Hi") }
            """
        let new = old.replacingOccurrences(of: "\"before\"", with: "\"after\"")
        let result = LiteralDiffer.diff(old: old, new: new)
        if case .literalOnly = result {
            Issue.record("Expected .structural for UIKit-region literal edit")
        }
    }

    @Test("UIViewRepresentable conformance — int change forces structural")
    func uiviewRepresentableForcesStructural() {
        let old = """
            import SwiftUI
            import UIKit
            struct MyWrapper: UIViewRepresentable {
                func makeUIView(context: Context) -> UIView {
                    let v = UIView()
                    v.tag = 42
                    return v
                }
                func updateUIView(_ uiView: UIView, context: Context) {}
            }
            #Preview { MyWrapper() }
            """
        let new = old.replacingOccurrences(of: "tag = 42", with: "tag = 99")
        let result = LiteralDiffer.diff(old: old, new: new)
        if case .literalOnly = result {
            Issue.record("Expected .structural for UIViewRepresentable literal edit")
        }
    }

    @Test("Function returning UIView — string change forces structural")
    func functionReturningUIViewForcesStructural() {
        let old = """
            import UIKit
            func makeLabel() -> UILabel {
                let l = UILabel()
                l.text = "before"
                return l
            }
            """
        let new = old.replacingOccurrences(of: "\"before\"", with: "\"after\"")
        let result = LiteralDiffer.diff(old: old, new: new)
        if case .literalOnly = result {
            Issue.record("Expected .structural for literal in UIKit-returning function")
        }
    }

    @Test("Mixed — SwiftUI literal change in UIKit-tainted file is still structural")
    func mixedFileTaintsAllUIKitLiterals() {
        // `MyWrapper` taints its body region. The SwiftUI literal in the
        // `#Preview` body is not tainted — only the UIKit-region edit is.
        // Editing the UIKit literal alone forces structural.
        let old = """
            import SwiftUI
            import UIKit
            struct MyWrapper: UIViewRepresentable {
                func makeUIView(context: Context) -> UIView {
                    let l = UILabel()
                    l.text = "uikitVal"
                    return l
                }
                func updateUIView(_ uiView: UIView, context: Context) {}
            }
            struct MyContent: View {
                var body: some View { Text("swiftUIVal") }
            }
            #Preview {
                VStack {
                    MyContent()
                    MyWrapper()
                }
            }
            """
        // SwiftUI-only edit — fast path is fine.
        let newSwiftUIOnly = old.replacingOccurrences(
            of: "\"swiftUIVal\"", with: "\"newSwiftUIVal\"")
        guard case .literalOnly = LiteralDiffer.diff(old: old, new: newSwiftUIOnly) else {
            Issue.record("Expected .literalOnly for pure SwiftUI literal edit")
            return
        }

        // UIKit-only edit — must be structural.
        let newUIKitOnly = old.replacingOccurrences(of: "\"uikitVal\"", with: "\"newUIKitVal\"")
        if case .literalOnly = LiteralDiffer.diff(old: old, new: newUIKitOnly) {
            Issue.record("Expected .structural for UIKit-region literal edit")
        }
    }

    @Test("Pure SwiftUI file — literal change still takes fast path")
    func pureSwiftUIPositiveControl() {
        // Positive control: ensures the taint check doesn't accidentally
        // demote SwiftUI bodies to .structural.
        let old = """
            import SwiftUI
            struct ContentView: View {
                var body: some View {
                    VStack(spacing: 12) {
                        Text("Hello")
                        Text("World")
                    }
                }
            }
            #Preview { ContentView() }
            """
        let new = old.replacingOccurrences(of: "\"Hello\"", with: "\"Hi\"")
        guard case .literalOnly(let changes) = LiteralDiffer.diff(old: old, new: new) else {
            Issue.record("Expected .literalOnly for pure SwiftUI literal edit")
            return
        }
        #expect(changes.count == 1)
        #expect(changes[0].newValue == .string("Hi"))
    }
}

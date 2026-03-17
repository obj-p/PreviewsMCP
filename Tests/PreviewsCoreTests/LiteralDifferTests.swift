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
        #expect(changes.count == 3) // spacing + two strings
    }
}

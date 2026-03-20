import Testing

@testable import PreviewsCore

@Suite("ThunkGenerator")
struct ThunkGeneratorTests {

    @Test("Replaces string literal in body")
    func stringReplacement() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hello") }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        #expect(result.source.contains("DesignTimeStore.shared.string(\"#0\", fallback: \"Hello\")"))
        #expect(result.literals.count == 1)
        #expect(result.literals[0].value == .string("Hello"))
    }

    @Test("Replaces integer literal in body")
    func integerReplacement() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { VStack(spacing: 20) { Text("Hi") } }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        #expect(result.source.contains("DesignTimeStore.shared.integer(\"#0\", fallback: 20)"))
        #expect(result.literals.count >= 1)
    }

    @Test("Replaces boolean literal in body")
    func booleanReplacement() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { Toggle(isOn: .constant(true)) { Text("T") } }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        #expect(result.source.contains("DesignTimeStore.shared.boolean("))
    }

    @Test("Skips string with interpolation")
    func skipsInterpolation() {
        let source = """
            import SwiftUI
            struct V: View {
                var x = 1
                var body: some View { Text("Count: \\(x)") }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        #expect(!result.source.contains("DesignTimeStore.shared.string"))
        // The interpolated string should remain unchanged
        #expect(result.source.contains("\"Count: \\(x)\""))
    }

    @Test("Skips stored property initializer")
    func skipsStoredProperty() {
        let source = """
            import SwiftUI
            struct V: View {
                @State private var count = 0
                var body: some View { Text("Hi") }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        // The 0 in @State should NOT be replaced
        #expect(result.source.contains("var count = 0"))
        // But "Hi" in body SHOULD be replaced
        #expect(result.source.contains("DesignTimeStore.shared.string(\"#0\", fallback: \"Hi\")"))
    }

    @Test("Skips macro argument")
    func skipsMacroArgument() {
        let source = """
            import SwiftUI
            struct V: View {
                var body: some View { Text("Hi") }
            }
            #Preview("Dark Mode") {
                V()
            }
            """
        let result = ThunkGenerator.transform(source: source)
        // "Dark Mode" in #Preview() should NOT be replaced
        #expect(result.source.contains("#Preview(\"Dark Mode\")"))
        // "Hi" in body SHOULD be replaced
        #expect(result.source.contains("DesignTimeStore.shared.string"))
    }

    @Test("Assigns sequential IDs")
    func sequentialIDs() {
        let source = """
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
        let result = ThunkGenerator.transform(source: source)
        #expect(result.literals.count == 3)  // 20, "Hello", "World"
        #expect(result.literals[0].id == "#0")
        #expect(result.literals[1].id == "#1")
        #expect(result.literals[2].id == "#2")
    }

    @Test("Replaces literals inside closures")
    func closureLiterals() {
        let source = """
            import SwiftUI
            struct V: View {
                @State var count = 0
                var body: some View {
                    Button("Tap") { count += 1 }
                }
            }
            """
        let result = ThunkGenerator.transform(source: source)
        // "Tap" and 1 should be replaced (inside body closure)
        #expect(result.source.contains("DesignTimeStore.shared.string"))
        #expect(result.source.contains("DesignTimeStore.shared.integer"))
        // count = 0 should NOT be replaced (stored property)
        #expect(result.source.contains("var count = 0"))
    }
}

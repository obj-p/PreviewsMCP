import Foundation
import Testing

@testable import PreviewsCore

/// Row 5 of the `@_dynamicReplacement` viability spike: `@Previewable @State`.
///
/// **This is the row the spike was most worried about.** The hypothesis in
/// `prompts/thunk-architecture.md` flagged the replacement boundary as
/// "unclear" — properties hoisted into the macro-generated closure.
///
/// **Symbol-table truth (Swift 6.2.3, Xcode 26.2):**
///
///   - `@Previewable` generates a local struct
///     `__P_Previewable_Transform_Wrapper` nested **inside an anonymous
///     closure inside** the `#Preview` macro's `makePreview()`. Full
///     demangled name (one line):
///
///       `__P_Previewable_Transform_Wrapper #1 in closure #1
///        @MainActor () -> SwiftUI.View in static <Module>.$s…
///        PreviewRegistryfMu_.makePreview() throws -> Preview`
///
///   - That wrapper's `body.getter` is **not** in the dynamically-replaceable
///     symbol list; only the outer `makePreview()` (which is itself
///     unspellable for the same reason as row 3) is replaceable.
///   - The `@Previewable` declaration itself + the closure-level expressions
///     inside `#Preview { ... }` therefore have **no named replacement
///     target** that a thunk can reference.
///
/// **Practical implication for the architecture.** The user view that the
/// closure body delegates to (here `CounterView`) still has a
/// dynamically-replaceable `body` (via `-enable-implicit-dynamic` applied
/// to the user module). So the thunk can hot-swap **the rendered content**
/// of a `@Previewable`-using preview, but **not** the `@Previewable`
/// declaration itself or the closure-level structure around it. Changes
/// inside the closure (adding a `@Previewable`, changing the `@State`
/// initial value, restructuring the closure expression) require a
/// stable-module rebuild.
///
/// Acceptable cost: `@Previewable` is typically set up once per preview and
/// edited rarely; the inner view's body — which IS what app authors iterate
/// on — remains hot-swappable.
@Suite("dynamic-replacement spike — row 5: @Previewable")
struct PreviewableDynamicReplacementTests {

    @Test("user view body inside #Preview { @Previewable ...; UserView() } is still replaceable")
    func userViewBodyInsidePreviewableIsReplaceable() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow5")
        defer { harness.cleanup() }

        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public struct CounterView: View {
                let count: Int
                public init(count: Int) { self.count = count }
                public var body: some View {
                    SPIKE_SENTINEL = 1
                    return Text("count: \\(count)")
                }
            }

            #Preview {
                @Previewable @State var count = 0
                CounterView(count: count)
            }

            @_cdecl("spike_invoke_counter_body")
            public func spike_invoke_counter_body() -> Int {
                SPIKE_SENTINEL = 0
                _ = CounterView(count: 42).body
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow5
            import SwiftUI

            extension CounterView {
                @_dynamicReplacement(for: body)
                public var __spike_body_replacement: some View {
                    SPIKE_SENTINEL = 2
                    return Text("thunked: \\(count)")
                }
            }
            """

        let stableDylib = try await harness.compileStable(
            source: stableSource, sourceName: "stable.swift")
        let thunkDylib = try await harness.compileThunk(
            source: thunkSource, sourceName: "thunk.swift")

        let stableHandle = try harness.dlopenStrict(stableDylib)
        let invoke: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_invoke_counter_body",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable CounterView.body sets sentinel = 1")

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, CounterView.body replacement sets sentinel = 2 even with @Previewable @State around it"
        )
    }
}

import Foundation
import Testing

@testable import PreviewsCore

/// Row 8 of the `@_dynamicReplacement` viability spike: can the thunk swap
/// a `@State` property's initial value without a stable rebuild?
///
/// Row 7 left this as the open boundary case. The naive approach is to
/// replace the wrapper's `init()`. The empirical finding here is **no**:
/// `@_dynamicReplacement` flatly refuses init replacement, even with
/// `-enable-implicit-dynamic` set + `public dynamic init()` declared
/// explicitly:
///
///   ```
///   error: replaced function 'init()' is not marked dynamic
///   ```
///
/// This persists across:
///   - implicit `init` synthesized by Swift
///   - user-declared `public init() { … }`
///   - user-declared `public dynamic init() { … }`
///
/// (The init's symbol IS in the dynamically-replaceable list per the
/// row 1 / row 5 symbol-table dumps, but the Swift frontend rejects
/// `@_dynamicReplacement(for: init())` at the source-resolution stage.
/// The two facts coexist because the "dynamically replaceable" symbol
/// metadata is emitted for any function under implicit-dynamic, but the
/// `@_dynamicReplacement` source-level check has its own list of what
/// it accepts as a target.)
///
/// **Workaround that DOES work — route construction through a factory.**
/// If the thunk generator emits a `makeInitialWrapper() ->
/// __PreviewWrapper_1` free function and has the `#Preview` closure call
/// it, replacing the factory swaps the default values of any `@State`
/// (or other stored) properties. This row tests the workaround as the
/// positive result: a default-value edit stays on the thunk-only fast
/// path when routed through a factory.
///
/// **Practical guidance for the thunk generator.** Emit a per-wrapper
/// factory: `#Preview { __PreviewWrapper_<n>.makeInitial() }` rather
/// than `#Preview { __PreviewWrapper_<n>() }`. Edits to the
/// `@Previewable @State` initial value compile into the factory's body,
/// which is replaceable. Body edits replace `__PreviewWrapper_<n>.body`
/// (rows 6 + 7). Only adding/removing `@Previewable` declarations still
/// requires a stable rebuild.
@Suite("dynamic-replacement spike — row 8: @State default via factory replacement")
struct InitReplacementDynamicReplacementTests {

    @Test("replacing a factory function swaps the default @State value (workaround for init)")
    func factoryReplacementSwapsStateDefault() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow8")
        defer { harness.cleanup() }

        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = -1

            public struct __PreviewWrapper_1: View {
                @State public var count: Int

                public init(count: Int) {
                    self._count = State(initialValue: count)
                }

                public var body: some View {
                    SPIKE_SENTINEL = count
                    return Text("count: \\(count)")
                }
            }

            // Factory the thunk generator would emit alongside the wrapper.
            // #Preview { __PreviewWrapper_1.makeInitial() } in user-facing
            // source rewrites to a call against this.
            public dynamic func makeInitialWrapper() -> __PreviewWrapper_1 {
                return __PreviewWrapper_1(count: 7)
            }

            #Preview {
                makeInitialWrapper()
            }

            @_cdecl("spike_invoke_factory_result")
            public func spike_invoke_factory_result() -> Int {
                SPIKE_SENTINEL = -1
                _ = makeInitialWrapper().body
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow8
            import SwiftUI

            @_dynamicReplacement(for: makeInitialWrapper())
            public func __makeInitialWrapper_replacement() -> __PreviewWrapper_1 {
                return __PreviewWrapper_1(count: 99)
            }
            """

        let stableDylib = try await harness.compileStable(
            source: stableSource, sourceName: "stable.swift")
        let thunkDylib = try await harness.compileThunk(
            source: thunkSource, sourceName: "thunk.swift")

        let stableHandle = try harness.dlopenStrict(stableDylib)
        let invoke: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_invoke_factory_result",
                as: (@convention(c) () -> Int).self)

        #expect(
            invoke() == 7,
            "stable factory constructs wrapper with @State initial value 7"
        )

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 99,
            "thunk-replaced factory constructs wrapper with @State initial value 99"
        )
    }
}

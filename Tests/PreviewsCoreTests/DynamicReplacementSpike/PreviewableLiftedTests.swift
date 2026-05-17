import Foundation
import Testing

@testable import PreviewsCore

/// Row 7 of the `@_dynamicReplacement` viability spike: `@Previewable @State`
/// lifted to a real `@State` property on a synthesized wrapper.
///
/// Row 5 verified that user-named view bodies referenced from inside a
/// `#Preview { @Previewable ...; UserView() }` closure stay replaceable.
/// What that row deliberately deferred was the v2 mitigation: have the
/// thunk generator lift `@Previewable` declarations out of the closure
/// onto a synthesized wrapper struct as real `@State` properties. The
/// spike doc treated this as plausibly viable but didn't empirically
/// confirm it.
///
/// This row confirms (or refutes) the v2 path. The post-rewrite stable
/// source looks like:
///
/// ```swift
/// public struct __PreviewWrapper_1: View {
///     @State public var count: Int = 0   // lifted from @Previewable
///     public var body: some View {
///         CounterView(count: count)
///     }
/// }
/// #Preview { __PreviewWrapper_1() }
/// ```
///
/// The thunk replaces `__PreviewWrapper_1.body`; the replacement body
/// references the same `count` property the wrapper owns. If `@State`
/// storage on the wrapper doesn't interfere with `@_dynamicReplacement
/// (for: body)`, the v2 mitigation is viable for the common case
/// (user authors `@Previewable @State`; build lifts it; body remains
/// hot-swappable).
///
/// **What the v2 path still can't cover.** Adding/removing a
/// `@Previewable` declaration changes the wrapper struct's stored-
/// property layout, which is an ABI break. The thunk cannot extend
/// the stable struct's storage; that genuinely requires a stable-
/// module rebuild. Documented here as a structural constraint rather
/// than tested — there's no positive assertion to make against an
/// "absence of capability."
@Suite("dynamic-replacement spike — row 7: @Previewable lifted to wrapper @State")
struct PreviewableLiftedDynamicReplacementTests {

    @Test("body replacement works on a wrapper whose @State was lifted from @Previewable")
    func liftedPreviewableBodyIsReplaceable() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow7")
        defer { harness.cleanup() }

        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0
            nonisolated(unsafe) public var SPIKE_COUNT_OBSERVED: Int = -1

            public struct CounterView: View {
                let count: Int
                public init(count: Int) { self.count = count }
                public var body: some View {
                    Text("count: \\(count)")
                }
            }

            public struct __PreviewWrapper_1: View {
                @State public var count: Int = 7    // lifted from @Previewable
                public init() {}
                public var body: some View {
                    SPIKE_SENTINEL = 1
                    SPIKE_COUNT_OBSERVED = count
                    return CounterView(count: count)
                }
            }

            #Preview {
                __PreviewWrapper_1()
            }

            @_cdecl("spike_invoke_lifted_wrapper")
            public func spike_invoke_lifted_wrapper() -> Int {
                SPIKE_SENTINEL = 0
                SPIKE_COUNT_OBSERVED = -1
                _ = __PreviewWrapper_1().body
                return SPIKE_SENTINEL
            }

            @_cdecl("spike_count_observed")
            public func spike_count_observed() -> Int {
                return SPIKE_COUNT_OBSERVED
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow7
            import SwiftUI

            extension __PreviewWrapper_1 {
                @_dynamicReplacement(for: body)
                public var __spike_body_replacement: some View {
                    SPIKE_SENTINEL = 2
                    SPIKE_COUNT_OBSERVED = count + 100  // references wrapper's @State
                    return CounterView(count: count)
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
                stableHandle, "spike_invoke_lifted_wrapper",
                as: (@convention(c) () -> Int).self)
        let countObserved: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_count_observed",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable wrapper body sets sentinel = 1")
        #expect(
            countObserved() == 7,
            "stable body reads the wrapper's @State initial value (7)"
        )

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, wrapper body replacement sets sentinel = 2"
        )
        #expect(
            countObserved() == 107,
            "replacement body reads the same @State property the stable wrapper owns (7 + 100)"
        )
    }
}

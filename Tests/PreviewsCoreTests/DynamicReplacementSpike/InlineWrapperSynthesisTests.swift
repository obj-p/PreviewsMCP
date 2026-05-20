import Foundation
import Testing

@testable import PreviewsCore

/// Row 6 of the `@_dynamicReplacement` viability spike: build-time wrapper
/// synthesis for inline `#Preview` bodies, plus multi-cycle hot-swap.
///
/// Naive `@_dynamicReplacement` can't reach a `#Preview { Text("hi") }` body
/// because the closure lives inside the unspellable macro-generated
/// `PreviewRegistry` type (rows 3 and 5). The mitigation the spike doc
/// proposes is a build-time syntactic rewrite: the thunk generator detects
/// inline-only `#Preview` blocks and rewrites them to delegate to a
/// synthesized named wrapper view.
///
/// This row validates two claims from that proposal:
///
///   1. **Single-cycle:** the synthesized wrapper's `body` is replaceable
///      via the same mechanism as a hand-written user view (mechanically
///      identical to row 3, but with a generator-style name to make the
///      simulation explicit).
///
///   2. **Multi-cycle identity stability:** the wrapper's name has to stay
///      the same across edits so `@_dynamicReplacement(for: body)` keeps
///      matching. Two thunks compiled against the same stable both
///      successfully replace the body; last-write-wins on the dispatch
///      table. This is what makes wrapper synthesis a *fast path* rather
///      than a stable rebuild in disguise — the wrapper struct is
///      compiled once, and every subsequent edit only re-emits the thunk.
///
/// Inline body chosen to mirror a realistic preview (modifier chain inside
/// a `VStack`) rather than the minimal `Text("hi")`, so the test exercises
/// what the synthesis path would do on real user code.
@Suite("dynamic-replacement spike — row 6: inline-body wrapper synthesis")
struct InlineWrapperSynthesisDynamicReplacementTests {

    @Test("synthesized __PreviewWrapper.body is replaceable across multiple thunk cycles")
    func wrapperSynthesisMultiCycle() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow6")
        defer { harness.cleanup() }

        // Post-synthesis stable source: the thunk generator wraps the
        // inline `#Preview { ... }` body in a generated `__PreviewWrapper_1`
        // before handing to swiftc. From swiftc's perspective this is
        // indistinguishable from hand-written user code.
        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public struct __PreviewWrapper_1: View {
                public init() {}
                public var body: some View {
                    SPIKE_SENTINEL = 1
                    return VStack {
                        Text("hi")
                            .font(.title)
                            .padding()
                    }
                }
            }

            #Preview {
                __PreviewWrapper_1()
            }

            @_cdecl("spike_invoke_wrapper")
            public func spike_invoke_wrapper() -> Int {
                SPIKE_SENTINEL = 0
                _ = __PreviewWrapper_1().body
                return SPIKE_SENTINEL
            }
            """

        // First "edit" — user changes the inline body. Thunk generator
        // emits a replacement targeting the (stable-identity) wrapper.
        let thunkSource1 = """
            @_private(sourceFile: "stable.swift") import SpikeRow6
            import SwiftUI

            extension __PreviewWrapper_1 {
                @_dynamicReplacement(for: body)
                public var __spike_body_replacement: some View {
                    SPIKE_SENTINEL = 2
                    return Text("edit 1")
                }
            }
            """

        // Second "edit" against the same wrapper struct. Distinct
        // thunk-module-name so the two thunks' dispatch-table
        // registrations don't collide at the symbol level.
        let thunkSource2 = """
            @_private(sourceFile: "stable.swift") import SpikeRow6
            import SwiftUI

            extension __PreviewWrapper_1 {
                @_dynamicReplacement(for: body)
                public var __spike_body_replacement: some View {
                    SPIKE_SENTINEL = 3
                    return Text("edit 2")
                }
            }
            """

        let stableDylib = try await harness.compileStable(
            source: stableSource, sourceName: "stable.swift")
        let thunk1Dylib = try await harness.compileThunk(
            source: thunkSource1, sourceName: "thunk1.swift",
            thunkModuleNameOverride: "SpikeRow6Thunk1")
        let thunk2Dylib = try await harness.compileThunk(
            source: thunkSource2, sourceName: "thunk2.swift",
            thunkModuleNameOverride: "SpikeRow6Thunk2")

        let stableHandle = try harness.dlopenStrict(stableDylib)
        let invoke: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_invoke_wrapper",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable wrapper body sets sentinel = 1")

        _ = try harness.dlopenStrict(thunk1Dylib)
        #expect(invoke() == 2, "after first thunk dlopen, body sets sentinel = 2")

        _ = try harness.dlopenStrict(thunk2Dylib)
        #expect(
            invoke() == 3,
            "after second thunk dlopen, body sets sentinel = 3 (multi-cycle hot-swap works)"
        )
    }
}

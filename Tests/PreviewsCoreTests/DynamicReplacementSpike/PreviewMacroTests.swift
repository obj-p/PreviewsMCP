import Foundation
import Testing

@testable import PreviewsCore

/// Row 3 of the `@_dynamicReplacement` viability spike: modern `#Preview`
/// macro wrapping a user-defined view.
///
/// **Empirical finding that changes the architecture assumption.** The
/// spike table in `prompts/thunk-architecture.md` hypothesized the
/// replacement target as "macro-expanded `static var body` on the
/// generated `PreviewRegistry` conformance." The actual symbol table
/// reveals two facts:
///
///   1. The `#Preview` macro does emit a `_PreviewRegistry`-conforming
///      type with a dynamically-replaceable `makePreview()`, BUT
///   2. The generated type's name is mangled and **unspellable in Swift
///      source** — e.g.
///      `$s9SpikeRow30017stableswift_yEEFcfMX12_0_33_98985398A8955F39628BBA33CE5E4D98Ll7PreviewfMf_15PreviewRegistryfMu_`.
///      This means `@_dynamicReplacement(for: <macro-type>.makePreview())`
///      cannot be written by a thunk.
///
/// Practical conclusion (matches Apple's pre-Xcode-16 pattern in
/// `docs/reverse-engineering.md:161-167`): the thunk replaces the user's
/// view bodies (e.g. `DummyView.body`), not the macro-generated wrapper.
/// The macro expansion stays unchanged across hot-reloads; what swaps
/// is the View's body, which the macro's render path calls into via
/// normal dynamic dispatch.
///
/// **Corollary that needs capturing in the architecture doc:** an
/// inline-body `#Preview { Text("hi") }` — where the closure constructs
/// a View tree without delegating to a user-named type — cannot be
/// hot-swapped via `@_dynamicReplacement` alone. The closure's body
/// lives inside the unspellable macro type. Such cases fall back to a
/// stable-module rebuild (Path B in thunk-architecture.md).
@Suite("dynamic-replacement spike — row 3: #Preview (modern macro)")
struct PreviewMacroDynamicReplacementTests {

    @Test("@_dynamicReplacement(for: body) replaces the user view body wrapped by #Preview")
    func previewMacroReplacesUserViewBody() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow3")
        defer { harness.cleanup() }

        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public struct DummyView: View {
                public init() {}
                public var body: some View {
                    SPIKE_SENTINEL = 1
                    return Text("dummy")
                }
            }

            #Preview {
                DummyView()
            }

            @_cdecl("spike_invoke_user_body")
            public func spike_invoke_user_body() -> Int {
                SPIKE_SENTINEL = 0
                _ = DummyView().body
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow3
            import SwiftUI

            extension DummyView {
                @_dynamicReplacement(for: body)
                public var __spike_body_replacement: some View {
                    SPIKE_SENTINEL = 2
                    return Text("thunked")
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
                stableHandle, "spike_invoke_user_body",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable DummyView.body sets sentinel = 1")

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, DummyView.body replacement sets sentinel = 2")
    }
}

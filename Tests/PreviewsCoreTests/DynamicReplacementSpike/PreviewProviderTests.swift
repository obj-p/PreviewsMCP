import Foundation
import Testing

@testable import PreviewsCore

/// Row 2 of the `@_dynamicReplacement` viability spike: legacy
/// `PreviewProvider`.
///
/// Hypothesis from `prompts/thunk-architecture.md` (table row 3): the
/// replacement target is the `previews` static var directly. This is the
/// shape `@_dynamicReplacement` was originally designed for pre-Xcode 16
/// (`docs/reverse-engineering.md:161-167`), so it should be the most
/// straightforward of the SwiftUI rows.
@Suite("dynamic-replacement spike — row 2: PreviewProvider")
struct PreviewProviderDynamicReplacementTests {

    @Test("@_dynamicReplacement(for: previews) replaces a PreviewProvider's static var")
    func previewProviderReplacement() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow2")
        defer { harness.cleanup() }

        let stableSource = """
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public struct DummyView: View {
                public init() {}
                public var body: some View { Text("dummy") }
            }

            public struct MyPreviews: PreviewProvider {
                public static var previews: some View {
                    SPIKE_SENTINEL = 1
                    return DummyView()
                }
            }

            @_cdecl("spike_invoke_previews")
            public func spike_invoke_previews() -> Int {
                SPIKE_SENTINEL = 0
                _ = MyPreviews.previews
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow2
            import SwiftUI

            extension MyPreviews {
                @_dynamicReplacement(for: previews)
                public static var __spike_previews_replacement: some View {
                    SPIKE_SENTINEL = 2
                    return DummyView()
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
                stableHandle, "spike_invoke_previews",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable previews body sets sentinel = 1")

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, replacement previews body sets sentinel = 2")
    }
}

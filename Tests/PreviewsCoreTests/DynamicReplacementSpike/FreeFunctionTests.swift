import Foundation
import Testing

@testable import PreviewsCore

/// Row 1 of the `@_dynamicReplacement` viability spike: free function.
///
/// Establishes the end-to-end harness invariant — compile stable + thunk
/// dylibs, dlopen both, observe that calling a `dynamic` free function
/// before vs. after thunk dlopen produces different observable effects.
///
/// Side-channel pattern: the body writes to a public global var; a
/// `@_cdecl` wrapper resets the global, calls the dynamic function, and
/// returns the post-call value. Tests dlsym the C wrapper and compare.
/// This pattern carries forward to every later row — the only thing that
/// changes per row is *what* shape's body the wrapper invokes.
@Suite("dynamic-replacement spike — row 1: free function")
struct FreeFunctionDynamicReplacementTests {

    @Test("@_dynamicReplacement(for:) replaces a free dynamic function body")
    func freeFunctionReplacement() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow1")
        defer { harness.cleanup() }

        let stableSource = """
            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public dynamic func spike_target() {
                SPIKE_SENTINEL = 1
            }

            @_cdecl("spike_invoke_target")
            public func spike_invoke_target() -> Int {
                SPIKE_SENTINEL = 0
                spike_target()
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow1

            @_dynamicReplacement(for: spike_target())
            public func __spike_target_replacement() {
                SPIKE_SENTINEL = 2
            }
            """

        let stableDylib = try await harness.compileStable(
            source: stableSource, sourceName: "stable.swift")
        let thunkDylib = try await harness.compileThunk(
            source: thunkSource, sourceName: "thunk.swift")

        let stableHandle = try harness.dlopenStrict(stableDylib)
        let invoke: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_invoke_target",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable body sets sentinel = 1")

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, replacement body sets sentinel = 2")
    }
}

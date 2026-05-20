import Foundation
import Testing

@testable import PreviewsCore

/// Row 4 of the `@_dynamicReplacement` viability spike: `#Preview { NSView }`
/// — macOS analogue of the UIKit row in `prompts/thunk-architecture.md`.
///
/// The spike table calls out the UIKit overload of the `__PreviewBridge.wrap`
/// path as a "same `static var body` returning a SwiftUI wrapper around the
/// UIKit view." The architectural question is: does the AppKit/UIKit
/// `#Preview` overload disturb `-enable-implicit-dynamic`'s reach into the
/// user functions that produce the platform view?
///
/// Strategy mirrors row 3: the thunk replaces the *user-named* function the
/// closure delegates to, not the macro expansion. The user provides
/// `makeAppKitView() -> NSView`; the `#Preview` macro's NSView overload
/// wraps it in a SwiftUI view; replacement of `makeAppKitView` is the
/// hot-swap surface.
///
/// **iOS-simulator validation is a documented follow-up.** Building this
/// fixture against `-target arm64-apple-ios-simulator` + `-sdk
/// iphonesimulator` would compile a UIKit equivalent; the harness's
/// invariants (compile both dylibs, dlopen, dlsym, observe sentinel) are
/// platform-independent. Deferred to keep the spike local-runnable and
/// focused on the per-shape viability question.
@Suite("dynamic-replacement spike — row 4: #Preview { NSView }")
struct AppKitPreviewDynamicReplacementTests {

    @Test("@_dynamicReplacement replaces the user function inside #Preview { NSView }")
    func appKitPreviewReplacement() async throws {
        let harness = try SpikeHarness(moduleName: "SpikeRow4")
        defer { harness.cleanup() }

        let stableSource = """
            import AppKit
            import SwiftUI

            nonisolated(unsafe) public var SPIKE_SENTINEL: Int = 0

            public dynamic func makeAppKitView() -> NSView {
                SPIKE_SENTINEL = 1
                return NSView()
            }

            #Preview {
                makeAppKitView()
            }

            @_cdecl("spike_invoke_appkit")
            public func spike_invoke_appkit() -> Int {
                SPIKE_SENTINEL = 0
                _ = makeAppKitView()
                return SPIKE_SENTINEL
            }
            """

        let thunkSource = """
            @_private(sourceFile: "stable.swift") import SpikeRow4
            import AppKit

            @_dynamicReplacement(for: makeAppKitView())
            public func __spike_makeAppKitView_replacement() -> NSView {
                SPIKE_SENTINEL = 2
                return NSView()
            }
            """

        let stableDylib = try await harness.compileStable(
            source: stableSource, sourceName: "stable.swift")
        let thunkDylib = try await harness.compileThunk(
            source: thunkSource, sourceName: "thunk.swift")

        let stableHandle = try harness.dlopenStrict(stableDylib)
        let invoke: @convention(c) () -> Int =
            try harness.dlsymOrFail(
                stableHandle, "spike_invoke_appkit",
                as: (@convention(c) () -> Int).self)

        #expect(invoke() == 1, "stable makeAppKitView sets sentinel = 1")

        _ = try harness.dlopenStrict(thunkDylib)

        #expect(
            invoke() == 2,
            "after thunk dlopen, makeAppKitView replacement sets sentinel = 2")
    }
}

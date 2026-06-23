import Foundation
@testable import PreviewsCore
import Testing

/// Regression coverage for #175: a `#Preview` whose state type is `@MainActor`-isolated
/// (the common `@Observable` view-model shape) must compile through the JIT bridge. The
/// render entry wraps the body in `MainActor.assumeIsolated`, so initializing and mutating
/// main-actor state inside the body type-checks. Before the dylib path was retired, the
/// nonisolated `createPreviewView`/`previewBodyKind` entries failed the whole-module compile.
struct MainActorPreviewBridgeTests {
    @Test("MainActor @Observable preview state compiles through the bridge")
    func mainActorObservableStateCompiles() async throws {
        let body = """
        let state = CounterState()
        state.count = 3
        return CounterView(state: state)
        """
        let source = """
        import SwiftUI

        @MainActor @Observable final class CounterState {
            var count = 0
        }

        struct CounterView: View {
            var state: CounterState
            var body: some View { Text("\\(state.count)") }
        }

        #Preview {
            \(body)
        }
        """

        let generated = BridgeGenerator.generateCombinedSource(
            originalSource: source,
            closureBody: body,
            renderOutputPath: "/tmp/previewsmcp-175-regression.png"
        )

        let compiler = try await Compiler()
        _ = try await compiler.compileObject(
            source: generated.source,
            moduleName: "MainActor175_\(UUID().uuidString.prefix(8))"
        )
    }
}

import PreviewsSetupKit
import SwiftUI

public struct SlowSetup: PreviewSetup {
    private nonisolated(unsafe) static var completed = false

    public static func setUp() async throws {
        try await Task.sleep(for: .seconds(8))
        completed = true
    }

    public static func wrap(_ content: AnyView) -> AnyView {
        AnyView(
            content.overlay(alignment: .bottom) {
                Text(completed ? "slow setup completed" : "slow setup incomplete")
                    .font(.caption)
            }
        )
    }
}

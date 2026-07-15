import PreviewsSetupKit
import SwiftUI

private struct IntentionalSetupError: LocalizedError {
    var errorDescription: String? {
        "intentional setup runtime failure"
    }
}

public struct ThrowingSetup: PreviewSetup {
    public static func setUp() async throws {
        throw IntentionalSetupError()
    }

    public static func wrap(_ content: AnyView) -> AnyView {
        AnyView(
            content.overlay(alignment: .bottom) {
                Text("throwing setup wrapper")
                    .font(.caption)
            }
        )
    }
}

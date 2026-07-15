import PreviewsSetupKit
import SwiftUI

public struct BrokenSetup: PreviewSetup {
    public static func wrap(_ content: AnyView) -> AnyView {
        let deliberatelyIncompleteDeclaration =
        return AnyView(content)
    }
}

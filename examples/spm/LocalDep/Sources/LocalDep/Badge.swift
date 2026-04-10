import SwiftUI

/// A small SwiftUI component in a separate local package.
/// Used to verify that SPMBuildSystem correctly links cross-package
/// dependencies resolved via `.package(path:)`.
public struct Badge: View {
    let text: String
    let color: Color

    public init(_ text: String, color: Color = .blue) {
        self.text = text
        self.color = color
    }

    public var body: some View {
        Text(text)
            .font(.caption2)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }
}

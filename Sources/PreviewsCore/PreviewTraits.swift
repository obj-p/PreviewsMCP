import Foundation

/// Configuration for SwiftUI rendering traits applied to a preview.
/// Traits are injected as view modifiers in the generated bridge code.
public struct PreviewTraits: Sendable {
    public var colorScheme: String?
    public var dynamicTypeSize: String?

    public init(colorScheme: String? = nil, dynamicTypeSize: String? = nil) {
        self.colorScheme = colorScheme
        self.dynamicTypeSize = dynamicTypeSize
    }

    public var isEmpty: Bool { colorScheme == nil && dynamicTypeSize == nil }

    /// Merge: non-nil values in `other` overwrite self.
    public func merged(with other: PreviewTraits) -> PreviewTraits {
        PreviewTraits(
            colorScheme: other.colorScheme ?? colorScheme,
            dynamicTypeSize: other.dynamicTypeSize ?? dynamicTypeSize
        )
    }

    public static let validColorSchemes: Set<String> = ["light", "dark"]

    public static let validDynamicTypeSizes: Set<String> = [
        "xSmall", "small", "medium", "large",
        "xLarge", "xxLarge", "xxxLarge",
        "accessibility1", "accessibility2", "accessibility3",
        "accessibility4", "accessibility5",
    ]
}

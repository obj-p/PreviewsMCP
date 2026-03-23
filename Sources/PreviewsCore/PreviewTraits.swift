import Foundation

/// Configuration for SwiftUI rendering traits applied to a preview.
/// Traits are injected as view modifiers in the generated bridge code.
public struct PreviewTraits: Sendable, Equatable {
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

    /// Validate optional trait values and return a PreviewTraits, or throw on invalid input.
    public static func validated(
        colorScheme: String?,
        dynamicTypeSize: String?
    ) throws -> PreviewTraits {
        if let cs = colorScheme, !validColorSchemes.contains(cs) {
            throw TraitValidationError.invalidColorScheme(cs)
        }
        if let dts = dynamicTypeSize, !validDynamicTypeSizes.contains(dts) {
            throw TraitValidationError.invalidDynamicTypeSize(dts)
        }
        return PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
    }
}

public enum TraitValidationError: Error, LocalizedError {
    case invalidColorScheme(String)
    case invalidDynamicTypeSize(String)

    public var errorDescription: String? {
        switch self {
        case .invalidColorScheme(let cs):
            return "Invalid color scheme '\(cs)'. Must be 'light' or 'dark'."
        case .invalidDynamicTypeSize(let dts):
            return
                "Invalid dynamic type size '\(dts)'. Valid values: \(PreviewTraits.validDynamicTypeSizes.sorted().joined(separator: ", "))"
        }
    }
}

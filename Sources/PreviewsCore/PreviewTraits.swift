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
            throw ValidationError.invalidColorScheme(cs)
        }
        if let dts = dynamicTypeSize, !validDynamicTypeSizes.contains(dts) {
            throw ValidationError.invalidDynamicTypeSize(dts)
        }
        return PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
    }

    /// Resolve a preset name to traits. Returns nil if unrecognized.
    public static func fromPreset(_ name: String) -> PreviewTraits? {
        if validColorSchemes.contains(name) {
            return PreviewTraits(colorScheme: name)
        }
        if validDynamicTypeSizes.contains(name) {
            return PreviewTraits(dynamicTypeSize: name)
        }
        return nil
    }

    /// All recognized preset names (color schemes + dynamic type sizes).
    public static var allPresetNames: Set<String> {
        validColorSchemes.union(validDynamicTypeSizes)
    }

    /// A trait variant resolved from a user-supplied string (preset name or JSON object).
    /// Used by both the MCP `preview_variants` tool and the CLI `variants` subcommand.
    public struct Variant: Sendable, Equatable {
        public let traits: PreviewTraits
        public let label: String
    }

    /// Resolve a variant string to a `Variant` (traits + label).
    ///
    /// Accepts:
    /// - A preset name from `allPresetNames` (light, dark, xSmall…accessibility5).
    ///   The label defaults to the preset name.
    /// - A JSON object string with `colorScheme` and/or `dynamicTypeSize` and an
    ///   optional `label` field. The default label joins non-nil trait values with `+`.
    ///
    /// Validates that:
    /// - At least one trait is set in JSON variants.
    /// - Trait values are valid (via `PreviewTraits.validated`).
    /// - The label is a valid filename component (no `/`, `\`, or leading `.`)
    ///   so callers can safely use it for output paths.
    public static func parseVariantString(_ str: String) throws -> Variant {
        let traits: PreviewTraits
        let label: String

        if let presetTraits = fromPreset(str) {
            traits = presetTraits
            label = str
        } else {
            guard let data = str.data(using: .utf8),
                let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else {
                throw VariantError.unknownPreset(str)
            }
            let cs = json["colorScheme"] as? String
            let dts = json["dynamicTypeSize"] as? String
            traits = try validated(colorScheme: cs, dynamicTypeSize: dts)
            if traits.isEmpty {
                throw VariantError.emptyVariantObject
            }
            label = (json["label"] as? String) ?? Self.defaultLabel(traits)
        }

        try Self.validateLabel(label)
        return Variant(traits: traits, label: label)
    }

    /// Filename-friendly default label derived from non-nil trait values, joined with `+`.
    public static func defaultLabel(_ traits: PreviewTraits) -> String {
        var parts: [String] = []
        if let cs = traits.colorScheme { parts.append(cs) }
        if let dts = traits.dynamicTypeSize { parts.append(dts) }
        return parts.joined(separator: "+")
    }

    /// Reject labels that aren't safe to use as a filename component.
    private static func validateLabel(_ label: String) throws {
        if label.isEmpty {
            throw VariantError.invalidLabel(label, reason: "label is empty")
        }
        if label.contains("/") || label.contains("\\") {
            throw VariantError.invalidLabel(label, reason: "label cannot contain '/' or '\\\\'")
        }
        if label.hasPrefix(".") {
            throw VariantError.invalidLabel(label, reason: "label cannot start with '.'")
        }
    }

    public enum ValidationError: Error, LocalizedError {
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

    public enum VariantError: Error, LocalizedError {
        case unknownPreset(String)
        case emptyVariantObject
        case invalidLabel(String, reason: String)

        public var errorDescription: String? {
            switch self {
            case .unknownPreset(let name):
                let presets = PreviewTraits.allPresetNames.sorted().joined(separator: ", ")
                return
                    "Unknown variant '\(name)'. Expected a preset name (\(presets)) or a JSON object string."
            case .emptyVariantObject:
                return
                    "Variant object must specify at least one trait (colorScheme or dynamicTypeSize)."
            case .invalidLabel(let label, let reason):
                return "Invalid variant label '\(label)': \(reason)."
            }
        }
    }
}

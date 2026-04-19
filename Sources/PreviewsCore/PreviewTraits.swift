import Foundation

/// Configuration for SwiftUI rendering traits applied to a preview.
/// Traits are injected as view modifiers in the generated bridge code.
public struct PreviewTraits: Sendable, Equatable {
    public var colorScheme: String?
    public var dynamicTypeSize: String?
    public var locale: String?
    public var layoutDirection: String?
    public var legibilityWeight: String?

    public init(
        colorScheme: String? = nil,
        dynamicTypeSize: String? = nil,
        locale: String? = nil,
        layoutDirection: String? = nil,
        legibilityWeight: String? = nil
    ) {
        self.colorScheme = colorScheme
        self.dynamicTypeSize = dynamicTypeSize
        self.locale = locale
        self.layoutDirection = layoutDirection
        self.legibilityWeight = legibilityWeight
    }

    public var isEmpty: Bool {
        colorScheme == nil && dynamicTypeSize == nil && locale == nil
            && layoutDirection == nil && legibilityWeight == nil
    }

    /// Merge: non-nil values in `other` overwrite self.
    public func merged(with other: PreviewTraits) -> PreviewTraits {
        PreviewTraits(
            colorScheme: other.colorScheme ?? colorScheme,
            dynamicTypeSize: other.dynamicTypeSize ?? dynamicTypeSize,
            locale: other.locale ?? locale,
            layoutDirection: other.layoutDirection ?? layoutDirection,
            legibilityWeight: other.legibilityWeight ?? legibilityWeight
        )
    }

    /// Identifies a single trait field. Used with `clearing(_:)` to null out
    /// a specific override without touching the others.
    public enum Field: String, Sendable, CaseIterable {
        case colorScheme
        case dynamicTypeSize
        case locale
        case layoutDirection
        case legibilityWeight
    }

    /// Return a copy with the given fields set to nil. Needed because
    /// `merged(with:)` alone can't clear — `other.x ?? self.x` preserves
    /// `self.x` when `other.x` is nil. Callers (e.g., the daemon's
    /// `preview_configure` handler) must explicitly ask to clear.
    public func clearing(_ fields: Set<Field>) -> PreviewTraits {
        PreviewTraits(
            colorScheme: fields.contains(.colorScheme) ? nil : colorScheme,
            dynamicTypeSize: fields.contains(.dynamicTypeSize) ? nil : dynamicTypeSize,
            locale: fields.contains(.locale) ? nil : locale,
            layoutDirection: fields.contains(.layoutDirection) ? nil : layoutDirection,
            legibilityWeight: fields.contains(.legibilityWeight) ? nil : legibilityWeight
        )
    }

    public static let validColorSchemes: Set<String> = ["light", "dark"]

    public static let validDynamicTypeSizes: Set<String> = [
        "xSmall", "small", "medium", "large",
        "xLarge", "xxLarge", "xxxLarge",
        "accessibility1", "accessibility2", "accessibility3",
        "accessibility4", "accessibility5",
    ]

    public static let validLayoutDirections: Set<String> = ["leftToRight", "rightToLeft"]

    public static let validLegibilityWeights: Set<String> = ["regular", "bold"]

    /// Normalize empty strings to nil (used for trait clearing).
    private static func normalize(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// Validate optional trait values and return a PreviewTraits, or throw on invalid input.
    /// Empty strings are treated as nil (clears the trait).
    /// Locale is not validated — any non-empty string is accepted.
    public static func validated(
        colorScheme: String? = nil,
        dynamicTypeSize: String? = nil,
        locale: String? = nil,
        layoutDirection: String? = nil,
        legibilityWeight: String? = nil
    ) throws -> PreviewTraits {
        let cs = normalize(colorScheme)
        let dts = normalize(dynamicTypeSize)
        let loc = normalize(locale)
        let ld = normalize(layoutDirection)
        let lw = normalize(legibilityWeight)

        if let cs, !validColorSchemes.contains(cs) {
            throw ValidationError.invalidColorScheme(cs)
        }
        if let dts, !validDynamicTypeSizes.contains(dts) {
            throw ValidationError.invalidDynamicTypeSize(dts)
        }
        if let loc, loc.contains("\"") || loc.contains("\\") || loc.contains("\n") {
            throw ValidationError.invalidLocale(loc)
        }
        if let ld, !validLayoutDirections.contains(ld) {
            throw ValidationError.invalidLayoutDirection(ld)
        }
        if let lw, !validLegibilityWeights.contains(lw) {
            throw ValidationError.invalidLegibilityWeight(lw)
        }
        return PreviewTraits(
            colorScheme: cs, dynamicTypeSize: dts, locale: loc,
            layoutDirection: ld, legibilityWeight: lw
        )
    }

    /// Resolve a preset name to traits. Returns nil if unrecognized.
    public static func fromPreset(_ name: String) -> PreviewTraits? {
        if validColorSchemes.contains(name) {
            return PreviewTraits(colorScheme: name)
        }
        if validDynamicTypeSizes.contains(name) {
            return PreviewTraits(dynamicTypeSize: name)
        }
        switch name {
        case "rtl": return PreviewTraits(layoutDirection: "rightToLeft")
        case "ltr": return PreviewTraits(layoutDirection: "leftToRight")
        case "boldText": return PreviewTraits(legibilityWeight: "bold")
        default: return nil
        }
    }

    /// All recognized preset names (color schemes + dynamic type sizes + layout/legibility).
    public static var allPresetNames: Set<String> {
        validColorSchemes.union(validDynamicTypeSizes).union(["rtl", "ltr", "boldText"])
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
    /// - A preset name from `allPresetNames` (light, dark, xSmall…accessibility5, rtl, ltr, boldText).
    ///   The label defaults to the preset name.
    /// - A JSON object string with any combination of `colorScheme`, `dynamicTypeSize`,
    ///   `locale`, `layoutDirection`, `legibilityWeight`, and an optional `label` field.
    ///   The default label joins non-nil trait values with `+`.
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
            let loc = json["locale"] as? String
            let ld = json["layoutDirection"] as? String
            let lw = json["legibilityWeight"] as? String
            traits = try validated(
                colorScheme: cs, dynamicTypeSize: dts, locale: loc,
                layoutDirection: ld, legibilityWeight: lw
            )
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
        if let loc = traits.locale { parts.append(loc) }
        if let ld = traits.layoutDirection { parts.append(ld) }
        if let lw = traits.legibilityWeight { parts.append(lw) }
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
        case invalidLocale(String)
        case invalidLayoutDirection(String)
        case invalidLegibilityWeight(String)

        public var errorDescription: String? {
            switch self {
            case .invalidColorScheme(let cs):
                return "Invalid color scheme '\(cs)'. Must be 'light' or 'dark'."
            case .invalidDynamicTypeSize(let dts):
                return
                    "Invalid dynamic type size '\(dts)'. Valid values: \(PreviewTraits.validDynamicTypeSizes.sorted().joined(separator: ", "))"
            case .invalidLocale(let loc):
                return
                    "Invalid locale '\(loc)'. Locale identifiers must not contain quotes, backslashes, or newlines."
            case .invalidLayoutDirection(let ld):
                return
                    "Invalid layout direction '\(ld)'. Must be 'leftToRight' or 'rightToLeft'."
            case .invalidLegibilityWeight(let lw):
                return "Invalid legibility weight '\(lw)'. Must be 'regular' or 'bold'."
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
                    "Variant object must specify at least one trait (colorScheme, dynamicTypeSize, locale, layoutDirection, or legibilityWeight)."
            case .invalidLabel(let label, let reason):
                return "Invalid variant label '\(label)': \(reason)."
            }
        }
    }
}

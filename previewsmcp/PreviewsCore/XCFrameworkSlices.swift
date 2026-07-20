import Foundation

/// Reads an `.xcframework/Info.plist` slice inventory: `AvailableLibraries`
/// entries with `LibraryIdentifier`, `SupportedPlatform`, and the optional
/// `SupportedPlatformVariant` ("simulator" for simulator slices). The F01
/// classifier consults it when a `no such module` build failure names a
/// declared binary target (docs/phase-error-protocol.md).
public enum XCFrameworkSlices {
    public struct Slice: Sendable {
        public let identifier: String
        public let platform: String?
        public let variant: String?

        public func matches(_ requested: PreviewPlatform) -> Bool {
            switch requested {
            case .iOS:
                platform == "ios" && variant == "simulator"
            case .macOS:
                platform == "macos"
            }
        }
    }

    /// One plist read; nil when the bundle or its inventory is unreadable —
    /// callers degrade rather than guess.
    public static func slices(in xcframework: URL) -> [Slice]? {
        let plist = xcframework.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any],
              let libraries = root["AvailableLibraries"] as? [[String: Any]]
        else { return nil }
        return libraries.compactMap { library in
            guard let identifier = library["LibraryIdentifier"] as? String else { return nil }
            return Slice(
                identifier: identifier,
                platform: library["SupportedPlatform"] as? String,
                variant: library["SupportedPlatformVariant"] as? String
            )
        }
    }
}

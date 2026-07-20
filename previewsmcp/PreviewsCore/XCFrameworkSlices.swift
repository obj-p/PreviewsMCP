import Foundation

/// Reads an `.xcframework/Info.plist` slice inventory: `AvailableLibraries`
/// entries with `LibraryIdentifier`, `SupportedPlatform`, and the optional
/// `SupportedPlatformVariant` ("simulator" for simulator slices). The F01
/// classifier consults it when a `no such module` build failure names a
/// declared binary target (docs/phase-error-protocol.md).
public enum XCFrameworkSlices {
    public static func availableIdentifiers(in xcframework: URL) -> [String]? {
        libraries(in: xcframework)?.compactMap { $0["LibraryIdentifier"] as? String }
    }

    public static func hasSlice(in xcframework: URL, for platform: PreviewPlatform) -> Bool {
        guard let libraries = libraries(in: xcframework) else { return false }
        return libraries.contains { library in
            let supported = library["SupportedPlatform"] as? String
            let variant = library["SupportedPlatformVariant"] as? String
            switch platform {
            case .iOS:
                return supported == "ios" && variant == "simulator"
            case .macOS:
                return supported == "macos"
            }
        }
    }

    private static func libraries(in xcframework: URL) -> [[String: Any]]? {
        let plist = xcframework.appendingPathComponent("Info.plist")
        guard let data = try? Data(contentsOf: plist),
              let root = try? PropertyListSerialization.propertyList(
                  from: data, format: nil
              ) as? [String: Any]
        else { return nil }
        return root["AvailableLibraries"] as? [[String: Any]]
    }
}

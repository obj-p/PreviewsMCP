import Foundation

public struct ProjectConfig: Sendable, Codable {
    public var platform: String?
    public var device: String?
    public var traits: TraitsConfig?
    public var quality: Double?
    public var setup: SetupConfig?

    public struct TraitsConfig: Sendable, Codable {
        public var colorScheme: String?
        public var dynamicTypeSize: String?
        public var locale: String?
        public var layoutDirection: String?
        public var legibilityWeight: String?

        public func toPreviewTraits() -> PreviewTraits {
            PreviewTraits(
                colorScheme: colorScheme,
                dynamicTypeSize: dynamicTypeSize,
                locale: locale,
                layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight
            )
        }
    }

    public struct SetupConfig: Sendable, Codable {
        public var moduleName: String
        public var typeName: String
    }
}

public enum ProjectConfigLoader {
    static let fileName = ".previewsmcp.json"

    public static func find(from directory: URL) -> ProjectConfig? {
        var dir = directory.standardizedFileURL
        while dir.path != "/" {
            let configFile = dir.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: configFile),
                let config = try? JSONDecoder().decode(ProjectConfig.self, from: data)
            {
                return config
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

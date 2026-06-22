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
            do {
                return try PreviewTraits.validated(
                    colorScheme: colorScheme,
                    dynamicTypeSize: dynamicTypeSize,
                    locale: locale,
                    layoutDirection: layoutDirection,
                    legibilityWeight: legibilityWeight
                )
            } catch {
                fputs(
                    "Warning: .previewsmcp.json traits invalid: \(error.localizedDescription). Using defaults.\n",
                    stderr
                )
                return PreviewTraits()
            }
        }
    }

    public struct SetupConfig: Sendable, Codable {
        public var moduleName: String
        public var typeName: String
        public var packagePath: String
    }
}

public enum ProjectConfigLoader {
    static let fileName = ".previewsmcp.json"

    /// Result of config discovery: the parsed config and the directory it was found in.
    public struct Result: Sendable {
        public let config: ProjectConfig
        public let directory: URL

        public init(config: ProjectConfig, directory: URL) {
            self.config = config
            self.directory = directory
        }
    }

    /// Walk up from `directory` looking for `.previewsmcp.json`. Returns the parsed
    /// config and the directory containing it, or nil if not found.
    public static func find(from directory: URL) -> Result? {
        var dir = directory.standardizedFileURL
        while dir.path != "/" {
            let configFile = dir.appendingPathComponent(fileName)
            if let data = try? Data(contentsOf: configFile),
                let config = try? JSONDecoder().decode(ProjectConfig.self, from: data)
            {
                return Result(config: config, directory: dir)
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}

import Foundation
import Testing

@testable import PreviewsCore

@Suite("ProjectConfig")
struct ProjectConfigTests {

    // MARK: - JSON Decoding

    @Test("Decodes full JSON with all fields")
    func decodesFullJSON() throws {
        let json = """
            {
                "platform": "ios",
                "device": "iPhone 16 Pro",
                "traits": {
                    "colorScheme": "dark",
                    "dynamicTypeSize": "large",
                    "locale": "ar",
                    "layoutDirection": "rightToLeft",
                    "legibilityWeight": "bold"
                },
                "quality": 0.9,
                "setup": {
                    "moduleName": "MyAppPreviewSetup",
                    "typeName": "AppPreviewSetup",
                    "packagePath": "../PreviewSetup"
                }
            }
            """
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(config.platform == "ios")
        #expect(config.device == "iPhone 16 Pro")
        #expect(config.traits?.colorScheme == "dark")
        #expect(config.traits?.dynamicTypeSize == "large")
        #expect(config.traits?.locale == "ar")
        #expect(config.traits?.layoutDirection == "rightToLeft")
        #expect(config.traits?.legibilityWeight == "bold")
        #expect(config.quality == 0.9)
        #expect(config.setup?.moduleName == "MyAppPreviewSetup")
        #expect(config.setup?.typeName == "AppPreviewSetup")
        #expect(config.setup?.packagePath == "../PreviewSetup")
    }

    @Test("Decodes minimal JSON with single field")
    func decodesMinimalJSON() throws {
        let json = """
            { "platform": "ios" }
            """
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(config.platform == "ios")
        #expect(config.device == nil)
        #expect(config.traits == nil)
        #expect(config.quality == nil)
        #expect(config.setup == nil)
    }

    @Test("Decodes empty JSON object")
    func decodesEmptyJSON() throws {
        let json = "{}"
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(config.platform == nil)
        #expect(config.device == nil)
        #expect(config.traits == nil)
    }

    @Test("Ignores unknown fields (forward-compatible)")
    func ignoresUnknownFields() throws {
        let json = """
            { "platform": "ios", "futureFeature": true, "nested": { "key": "value" } }
            """
        let config = try JSONDecoder().decode(ProjectConfig.self, from: Data(json.utf8))
        #expect(config.platform == "ios")
    }

    // MARK: - TraitsConfig conversion

    @Test("TraitsConfig.toPreviewTraits converts all fields")
    func traitsConfigConversion() {
        let tc = ProjectConfig.TraitsConfig(
            colorScheme: "dark",
            dynamicTypeSize: "large",
            locale: "ar",
            layoutDirection: "rightToLeft",
            legibilityWeight: "bold"
        )
        let traits = tc.toPreviewTraits()
        #expect(traits.colorScheme == "dark")
        #expect(traits.dynamicTypeSize == "large")
        #expect(traits.locale == "ar")
        #expect(traits.layoutDirection == "rightToLeft")
        #expect(traits.legibilityWeight == "bold")
    }

    @Test("TraitsConfig.toPreviewTraits handles nil fields")
    func traitsConfigConversionNil() {
        let tc = ProjectConfig.TraitsConfig(colorScheme: "light")
        let traits = tc.toPreviewTraits()
        #expect(traits.colorScheme == "light")
        #expect(traits.dynamicTypeSize == nil)
        #expect(traits.locale == nil)
    }

    // MARK: - ProjectConfigLoader

    @Test("find returns nil when no config exists")
    func findReturnsNilNoConfig() {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let config = ProjectConfigLoader.find(from: tempDir)
        #expect(config == nil)
    }

    @Test("find discovers config in same directory")
    func findInSameDirectory() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configFile = tempDir.appendingPathComponent(".previewsmcp.json")
        try Data(
            """
            { "platform": "ios" }
            """.utf8
        ).write(to: configFile)

        let config = ProjectConfigLoader.find(from: tempDir)
        #expect(config?.platform == "ios")
    }

    @Test("find walks up to parent directory")
    func findWalksUpDirectories() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let child = root.appendingPathComponent("Sources").appendingPathComponent("Feature")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let configFile = root.appendingPathComponent(".previewsmcp.json")
        try Data(
            """
            { "platform": "macos", "quality": 0.95 }
            """.utf8
        ).write(to: configFile)

        let config = ProjectConfigLoader.find(from: child)
        #expect(config?.platform == "macos")
        #expect(config?.quality == 0.95)
    }

    @Test("find returns nil for malformed JSON")
    func findReturnsNilMalformedJSON() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let configFile = tempDir.appendingPathComponent(".previewsmcp.json")
        try Data("not json".utf8).write(to: configFile)

        let config = ProjectConfigLoader.find(from: tempDir)
        #expect(config == nil)
    }
}

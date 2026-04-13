import Foundation
import Testing

@testable import PreviewsCore

@Suite("SetupBuilder")
struct SetupBuilderTests {

    // MARK: - Result struct

    @Test("SetupBuilder.Result includes dylibPath field")
    func resultIncludesDylibPath() {
        let result = SetupBuilder.Result(
            moduleName: "TestSetup",
            typeName: "AppSetup",
            compilerFlags: ["-I", "/some/path"],
            dylibPath: URL(fileURLWithPath: "/tmp/libPreviewSetup.dylib")
        )

        #expect(result.moduleName == "TestSetup")
        #expect(result.typeName == "AppSetup")
        #expect(result.dylibPath.lastPathComponent == "libPreviewSetup.dylib")
        #expect(result.compilerFlags.contains("-I"))
    }

    // MARK: - Build with real example setup package

    @Test("SetupBuilder builds example setup package for macOS and produces dylib")
    func buildExampleSetupMacOS() async throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // Tests/PreviewsCoreTests
            .deletingLastPathComponent()  // Tests
            .deletingLastPathComponent()  // repo root

        let configURL = repoRoot.appendingPathComponent("examples/.previewsmcp.json")
        guard FileManager.default.fileExists(atPath: configURL.path) else { return }
        let data = try Data(contentsOf: configURL)
        let config = try JSONDecoder().decode(ProjectConfig.self, from: data)
        guard let setup = config.setup else { return }

        let configDirectory = configURL.deletingLastPathComponent()
        let result = try await SetupBuilder.build(
            config: setup,
            configDirectory: configDirectory,
            platform: .macOS
        )

        // Verify the dylib was produced
        #expect(FileManager.default.fileExists(atPath: result.dylibPath.path))
        #expect(result.dylibPath.pathExtension == "dylib")
        #expect(result.dylibPath.lastPathComponent == "libPreviewSetup.dylib")

        // Verify compiler flags include module search path and dylib linking
        #expect(result.compilerFlags.contains("-I"))
        #expect(result.compilerFlags.contains("-L"))
        #expect(result.compilerFlags.contains("-lPreviewSetup"))

        // Verify no -undefined dynamic_lookup
        #expect(!result.compilerFlags.contains("dynamic_lookup"))
    }

    // MARK: - Error cases

    @Test("SetupBuilder throws packageNotFound for missing directory")
    func missingPackageThrows() async throws {
        let json = """
            {"moduleName": "DoesNotExist", "typeName": "Setup", "packagePath": "nonexistent"}
            """
        let config = try JSONDecoder().decode(
            ProjectConfig.SetupConfig.self, from: json.data(using: .utf8)!
        )

        do {
            _ = try await SetupBuilder.build(
                config: config,
                configDirectory: FileManager.default.temporaryDirectory,
                platform: .macOS
            )
            Issue.record("Expected SetupBuilderError.packageNotFound")
        } catch let error as SetupBuilderError {
            if case .packageNotFound = error {
                // expected
            } else {
                Issue.record("Expected packageNotFound, got: \(error)")
            }
        }
    }
}

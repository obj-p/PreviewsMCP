import Foundation
import Testing

@testable import PreviewsCore

@Suite("SetupCache")
struct SetupCacheTests {

    // MARK: - Helpers

    /// Create a minimal SPM package directory with Package.swift and one source file.
    private func makePackageDir(
        packageSwift: String =
            "// swift-tools-version: 6.0\nimport PackageDescription\nlet package = Package(name: \"TestSetup\")\n",
        sourceContent: String = "public struct TestSetup {}\n"
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = dir.appendingPathComponent("Sources").appendingPathComponent("TestSetup")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)
        try Data(packageSwift.utf8).write(to: dir.appendingPathComponent("Package.swift"))
        try Data(sourceContent.utf8).write(
            to: sourcesDir.appendingPathComponent("TestSetup.swift"))
        return dir
    }

    // MARK: - hashSources

    @Test("hashSources returns stable result across calls")
    func hashSources_stableAcrossRuns() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(packageDir: dir)
        let hash2 = try SetupCache.hashSources(packageDir: dir)
        #expect(hash1 == hash2)
        #expect(hash1.count == 64)
    }

    @Test("hashSources changes when Package.swift changes")
    func hashSources_sensitiveToPackageSwift() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(packageDir: dir)
        try Data("// modified\n".utf8).write(to: dir.appendingPathComponent("Package.swift"))
        let hash2 = try SetupCache.hashSources(packageDir: dir)
        #expect(hash1 != hash2)
    }

    @Test("hashSources changes when a Swift source file changes")
    func hashSources_sensitiveToSwiftSource() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(packageDir: dir)
        let sourceFile = dir.appendingPathComponent("Sources/TestSetup/TestSetup.swift")
        try Data("public struct Modified {}\n".utf8).write(to: sourceFile)
        let hash2 = try SetupCache.hashSources(packageDir: dir)
        #expect(hash1 != hash2)
    }

    @Test("hashSources changes when Package.resolved changes")
    func hashSources_sensitiveToPackageResolved() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(packageDir: dir)
        try Data("{\"version\": 1}\n".utf8).write(
            to: dir.appendingPathComponent("Package.resolved"))
        let hash2 = try SetupCache.hashSources(packageDir: dir)
        #expect(hash1 != hash2)
    }

    @Test("hashSources only hashes Package.swift, Package.resolved, and Sources/**/*.swift")
    func hashSources_onlyHashesPackageAndSources() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(packageDir: dir)

        // Add files that should not affect the hash
        let testsDir = dir.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: testsDir, withIntermediateDirectories: true)
        try Data("test".utf8).write(to: testsDir.appendingPathComponent("SomeTest.swift"))
        try Data("readme".utf8).write(to: dir.appendingPathComponent("README.md"))
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try Data("artifact".utf8).write(to: buildDir.appendingPathComponent("cached.o"))

        let hash2 = try SetupCache.hashSources(packageDir: dir)
        #expect(hash1 == hash2)
    }

    @Test("hashSources changes when sdkPath differs")
    func hashSources_sensitiveToSdkPath() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hashNoSDK = try SetupCache.hashSources(packageDir: dir)
        let hashSDK1 = try SetupCache.hashSources(
            packageDir: dir, sdkPath: "/Xcode_16.0/iPhoneSimulator.sdk")
        let hashSDK2 = try SetupCache.hashSources(
            packageDir: dir, sdkPath: "/Xcode_16.1/iPhoneSimulator.sdk")

        #expect(hashNoSDK != hashSDK1)
        #expect(hashSDK1 != hashSDK2)
    }

    @Test("hashSources changes when swiftVersion differs")
    func hashSources_sensitiveToSwiftVersion() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let hash1 = try SetupCache.hashSources(
            packageDir: dir, swiftVersion: "Swift 6.0")
        let hash2 = try SetupCache.hashSources(
            packageDir: dir, swiftVersion: "Swift 6.1")
        let hashNil = try SetupCache.hashSources(packageDir: dir)

        #expect(hash1 != hash2)
        #expect(hash1 != hashNil)
    }

    // MARK: - resolveSwiftVersion

    @Test("resolveSwiftVersion returns a non-empty string containing Swift")
    func resolveSwiftVersion_returnsNonEmpty() async throws {
        let version = try await SetupCache.resolveSwiftVersion()
        #expect(!version.isEmpty)
        #expect(version.contains("Swift"))
    }

    // MARK: - Store / Load

    /// Create a fake build artifacts directory that matches expected compiler flags.
    private func makeArtifacts(packageDir: URL, moduleName: String) throws -> [String] {
        let buildDir = packageDir.appendingPathComponent(".build/debug")
        let modulesDir = buildDir.appendingPathComponent("Modules")
        try FileManager.default.createDirectory(
            at: modulesDir, withIntermediateDirectories: true)

        // Create .swiftmodule with content (validation checks non-empty)
        let swiftmoduleDir = modulesDir.appendingPathComponent("\(moduleName).swiftmodule")
        try FileManager.default.createDirectory(
            at: swiftmoduleDir, withIntermediateDirectories: true)
        try Data("fake".utf8).write(
            to: swiftmoduleDir.appendingPathComponent("arm64-apple-macos.swiftmodule"))

        // Create static library
        try Data("fake".utf8).write(
            to: buildDir.appendingPathComponent("lib\(moduleName).a"))

        return ["-I", modulesDir.path, "-L", buildDir.path, "-l\(moduleName)"]
    }

    @Test("load returns nil when no cache file exists")
    func load_missReturnsNil() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let result = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "abc123",
            swiftVersion: "Swift 6.0")
        #expect(result == nil)
    }

    @Test("load returns nil and deletes corrupt JSON")
    func load_corruptJsonReturnsNilAndDeletes() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Write garbage to the cache file path
        let cacheDir = dir.appendingPathComponent(".build/\(SetupCache.cacheDirectory)")
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        let cacheFile = cacheDir.appendingPathComponent("macos-abc123.json")
        try Data("not valid json".utf8).write(to: cacheFile)

        let result = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "abc123",
            swiftVersion: "Swift 6.0")
        #expect(result == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheFile.path))
    }

    @Test("load returns nil when .swiftmodule artifact is missing")
    func load_missingArtifactReturnsNil() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Store a valid entry with flags pointing to non-existent paths
        let fakeResult = SetupBuilder.Result(
            moduleName: "TestSetup", typeName: "Setup",
            compilerFlags: ["-I", "/nonexistent/Modules", "-L", "/nonexistent"])
        SetupCache.store(
            fakeResult, packageDir: dir, platform: .macOS,
            sourceHash: "abc123", swiftVersion: "Swift 6.0")

        let loaded = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "abc123",
            swiftVersion: "Swift 6.0")
        #expect(loaded == nil)
    }

    @Test("load returns nil when static library is missing")
    func load_missingStaticLibReturnsNil() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Create modules dir + swiftmodule (with content) but no .a file
        let buildDir = dir.appendingPathComponent(".build/debug")
        let modulesDir = buildDir.appendingPathComponent("Modules")
        let swiftmoduleDir = modulesDir.appendingPathComponent("TestSetup.swiftmodule")
        try FileManager.default.createDirectory(
            at: swiftmoduleDir, withIntermediateDirectories: true)
        try Data("fake".utf8).write(
            to: swiftmoduleDir.appendingPathComponent("arm64.swiftmodule"))

        let fakeResult = SetupBuilder.Result(
            moduleName: "TestSetup", typeName: "Setup",
            compilerFlags: ["-I", modulesDir.path, "-L", buildDir.path, "-lTestSetup"])
        SetupCache.store(
            fakeResult, packageDir: dir, platform: .macOS,
            sourceHash: "abc123", swiftVersion: "Swift 6.0")

        let loaded = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "abc123",
            swiftVersion: "Swift 6.0")
        #expect(loaded == nil)
    }

    @Test("store then load round-trips all fields")
    func store_thenLoad_roundTrip() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let flags = try makeArtifacts(packageDir: dir, moduleName: "TestSetup")
        let original = SetupBuilder.Result(
            moduleName: "TestSetup", typeName: "AppSetup", compilerFlags: flags)

        SetupCache.store(
            original, packageDir: dir, platform: .macOS,
            sourceHash: "def456", swiftVersion: "Swift 6.0")

        let loaded = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "def456",
            swiftVersion: "Swift 6.0")

        #expect(loaded != nil)
        #expect(loaded?.moduleName == "TestSetup")
        #expect(loaded?.typeName == "AppSetup")
        #expect(loaded?.compilerFlags == flags)
    }

    @Test("store does not throw on read-only parent directory")
    func store_ioFailureDoesNotThrow() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-readonly-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        // Make .build read-only so cache dir creation fails
        let buildDir = dir.appendingPathComponent(".build")
        try FileManager.default.createDirectory(at: buildDir, withIntermediateDirectories: true)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: buildDir.path)
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: buildDir.path)
        }

        let result = SetupBuilder.Result(
            moduleName: "Test", typeName: "Setup", compilerFlags: [])
        // Should not throw — errors are swallowed
        SetupCache.store(
            result, packageDir: dir, platform: .macOS,
            sourceHash: "xyz", swiftVersion: "Swift 6.0")
    }

    // MARK: - Platform Isolation

    @Test("macOS and iOS cache entries coexist independently")
    func platformIsolation_bothCached() throws {
        let dir = try makePackageDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let macFlags = try makeArtifacts(packageDir: dir, moduleName: "TestSetup")
        let macResult = SetupBuilder.Result(
            moduleName: "TestSetup", typeName: "Setup", compilerFlags: macFlags)

        // Create separate iOS artifacts
        let iosBuildDir = dir.appendingPathComponent(".build/ios-debug")
        let iosModulesDir = iosBuildDir.appendingPathComponent("Modules")
        let iosSwiftmodule = iosModulesDir.appendingPathComponent("TestSetup.swiftmodule")
        try FileManager.default.createDirectory(
            at: iosSwiftmodule, withIntermediateDirectories: true)
        try Data("fake".utf8).write(
            to: iosSwiftmodule.appendingPathComponent("arm64.swiftmodule"))
        try Data("fake".utf8).write(
            to: iosBuildDir.appendingPathComponent("libTestSetup.a"))
        let iosFlags = ["-I", iosModulesDir.path, "-L", iosBuildDir.path, "-lTestSetup"]
        let iosResult = SetupBuilder.Result(
            moduleName: "TestSetup", typeName: "Setup", compilerFlags: iosFlags)

        // Store both
        SetupCache.store(
            macResult, packageDir: dir, platform: .macOS,
            sourceHash: "samehash", swiftVersion: "Swift 6.0")
        SetupCache.store(
            iosResult, packageDir: dir, platform: .iOS,
            sourceHash: "samehash", swiftVersion: "Swift 6.0")

        // Both should load independently
        let loadedMac = SetupCache.load(
            packageDir: dir, platform: .macOS, sourceHash: "samehash",
            swiftVersion: "Swift 6.0")
        let loadedIOS = SetupCache.load(
            packageDir: dir, platform: .iOS, sourceHash: "samehash",
            swiftVersion: "Swift 6.0")

        #expect(loadedMac != nil)
        #expect(loadedIOS != nil)
        #expect(loadedMac?.compilerFlags != loadedIOS?.compilerFlags)
    }

    // MARK: - Integration Tests (real SetupBuilder.build)

    /// Create a buildable SPM package with PreviewsSetupKit dependency.
    private func makeBuildablePackage() throws -> (dir: URL, config: ProjectConfig.SetupConfig) {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString)")
        let sourcesDir = dir.appendingPathComponent("Sources/TestSetup")
        try FileManager.default.createDirectory(at: sourcesDir, withIntermediateDirectories: true)

        let packageSwift = """
            // swift-tools-version: 6.0
            import PackageDescription
            let package = Package(
                name: "TestSetup",
                platforms: [.macOS(.v14)],
                products: [.library(name: "TestSetup", targets: ["TestSetup"])],
                targets: [.target(name: "TestSetup")]
            )
            """
        try Data(packageSwift.utf8).write(to: dir.appendingPathComponent("Package.swift"))

        let source = """
            public struct TestSetup {
                public static func hello() -> String { "hello" }
            }
            """
        try Data(source.utf8).write(to: sourcesDir.appendingPathComponent("TestSetup.swift"))

        let config = ProjectConfig.SetupConfig(
            moduleName: "TestSetup", typeName: "TestSetup", packagePath: ".")
        return (dir, config)
    }

    @Test("Warm cache skips swift build and returns identical result")
    func build_warmCacheSkipsSwiftBuild() async throws {
        let (dir, config) = try makeBuildablePackage()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Cold build
        let coldResult = try await SetupBuilder.build(
            config: config, configDirectory: dir, platform: .macOS)

        // Verify cache file exists on disk
        let cacheDir = dir.appendingPathComponent(".build/\(SetupCache.cacheDirectory)")
        let filesAfterCold = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil)
        #expect(filesAfterCold.count >= 1, "Cache file should exist after cold build")

        // Warm build
        let warmResult = try await SetupBuilder.build(
            config: config, configDirectory: dir, platform: .macOS)

        // No new cache file written — proves the cache was hit, not rebuilt
        let filesAfterWarm = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil)
        #expect(coldResult == warmResult, "Warm result must equal cold result")
        #expect(
            filesAfterWarm.count == filesAfterCold.count,
            "No new cache entry should be written on cache hit")
    }

    @Test("Source change invalidates cache and triggers rebuild")
    func build_invalidatesCacheOnSourceChange() async throws {
        let (dir, config) = try makeBuildablePackage()
        defer { try? FileManager.default.removeItem(at: dir) }

        // First build populates cache
        let result1 = try await SetupBuilder.build(
            config: config, configDirectory: dir, platform: .macOS)

        // List cache files before modification
        let cacheDir = dir.appendingPathComponent(".build/\(SetupCache.cacheDirectory)")
        let filesBefore = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        )
        .map(\.lastPathComponent)

        // Modify source
        let sourceFile = dir.appendingPathComponent("Sources/TestSetup/TestSetup.swift")
        try Data(
            "public struct TestSetup { public static func world() -> String { \"world\" } }\n"
                .utf8
        ).write(to: sourceFile)

        // Second build should create a new cache entry with different hash
        let result2 = try await SetupBuilder.build(
            config: config, configDirectory: dir, platform: .macOS)

        let filesAfter = try FileManager.default.contentsOfDirectory(
            at: cacheDir, includingPropertiesForKeys: nil
        )
        .map(\.lastPathComponent)

        // Different source → different hash → different cache filename
        #expect(filesAfter.count >= 2, "Should have both old and new cache entries")
        #expect(result1.moduleName == result2.moduleName)
        #expect(
            Set(filesAfter).isStrictSuperset(of: Set(filesBefore)),
            "New cache entry should be added alongside old one")
    }
}

import Foundation

/// Builds a setup plugin package and returns compiler flags for importing its module.
public enum SetupBuilder {

    public struct Result: Sendable, Equatable {
        public let moduleName: String
        public let typeName: String
        public let compilerFlags: [String]
        /// Path to the setup dynamic library. Must be loaded with RTLD_GLOBAL
        /// before any preview dylib so all preview dylibs share the same statics.
        public let dylibPath: URL
    }

    /// Build the setup package and return flags needed to compile bridge code that imports it.
    ///
    /// - Parameters:
    ///   - config: The setup configuration from `.previewsmcp.json`.
    ///   - configDirectory: The directory containing `.previewsmcp.json` (used to resolve relative paths).
    ///   - platform: Target platform (macOS or iOS simulator).
    public static func build(
        config: ProjectConfig.SetupConfig,
        configDirectory: URL,
        platform: PreviewPlatform
    ) async throws -> Result {
        let packageDir = configDirectory.appendingPathComponent(config.packagePath).standardizedFileURL

        guard
            FileManager.default.fileExists(
                atPath: packageDir.appendingPathComponent("Package.swift").path
            )
        else {
            throw SetupBuilderError.packageNotFound(packageDir.path)
        }

        // Resolve inputs for the cache key before checking the cache.
        let iosSDKPath: String? = platform == .iOS ? try await resolveIOSSDK() : nil
        let swiftVersion = try await SetupCache.resolveSwiftVersion()
        let sourceHash = try SetupCache.hashSources(
            packageDir: packageDir, sdkPath: iosSDKPath, swiftVersion: swiftVersion)

        if let cached = SetupCache.load(
            packageDir: packageDir,
            platform: platform,
            sourceHash: sourceHash,
            swiftVersion: swiftVersion
        ) {
            return cached
        }

        var buildArgs = ["swift", "build", "--package-path", packageDir.path]
        if let sdkPath = iosSDKPath {
            buildArgs += ["--triple", PreviewPlatform.iOS.targetTriple, "--sdk", sdkPath]
        }

        let buildResult = try await runAsync("/usr/bin/env", arguments: buildArgs)
        guard buildResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: config.moduleName,
                stderr: buildResult.stderr.isEmpty ? buildResult.stdout : buildResult.stderr
            )
        }

        var binPathArgs = ["swift", "build", "--package-path", packageDir.path, "--show-bin-path"]
        if let sdkPath = iosSDKPath {
            binPathArgs += ["--triple", PreviewPlatform.iOS.targetTriple, "--sdk", sdkPath]
        }

        let binPathResult = try await runAsync("/usr/bin/env", arguments: binPathArgs)
        guard binPathResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: config.moduleName, stderr: binPathResult.stderr
            )
        }

        let binPath = URL(fileURLWithPath: binPathResult.stdout)
        let modulesDir = binPath.appendingPathComponent("Modules")

        guard
            FileManager.default.fileExists(
                atPath: modulesDir.appendingPathComponent("\(config.moduleName).swiftmodule").path
            )
        else {
            throw SetupBuilderError.moduleNotFound(
                config.moduleName, searchPath: modulesDir.path
            )
        }

        // Link .o files into a dynamic library so all preview dylibs share the same statics.
        // Static linking (.a) gives each preview dylib its own copy of statics, which breaks
        // setUp() state persistence across hot-reload cycles (see issue #86).
        let dylibPath = try await linkDynamicLibrary(binPath: binPath, platform: platform)

        var flags: [String] = [
            "-I", modulesDir.path,
            // Let the linker resolve setup symbols at runtime from the RTLD_GLOBAL-loaded
            // setup dylib rather than statically linking setup code into each preview dylib.
            "-Xlinker", "-undefined", "-Xlinker", "dynamic_lookup",
        ]

        let frameworkNames = collectFrameworks(binPath: binPath)
        if !frameworkNames.isEmpty {
            flags += ["-F", binPath.path]
            for fw in frameworkNames {
                flags += ["-framework", fw]
            }
            flags += ["-Xlinker", "-rpath", "-Xlinker", binPath.path]
        }

        let result = Result(
            moduleName: config.moduleName,
            typeName: config.typeName,
            compilerFlags: flags,
            dylibPath: dylibPath
        )

        SetupCache.store(
            result,
            packageDir: packageDir,
            platform: platform,
            sourceHash: sourceHash,
            swiftVersion: swiftVersion
        )

        return result
    }

    /// Link .o files from all target build directories into a single dynamic library.
    /// This ensures all preview dylibs share the same statics from the setup module.
    private static func linkDynamicLibrary(
        binPath: URL,
        platform: PreviewPlatform
    ) async throws -> URL {
        let fm = FileManager.default
        var allObjectFiles: [URL] = []

        if let entries = try? fm.contentsOfDirectory(
            at: binPath, includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) {
            for entry in entries {
                let name = entry.lastPathComponent
                guard name.hasSuffix(".build") else { continue }
                var isDir: ObjCBool = false
                guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue
                else { continue }
                let targetName = String(name.dropLast(".build".count))
                if targetName.hasPrefix("_") { continue }
                allObjectFiles.append(contentsOf: collectObjectFiles(in: entry))
            }
        }

        guard !allObjectFiles.isEmpty else {
            throw SetupBuilderError.buildFailed(
                package: "setup", stderr: "No object files found to link"
            )
        }

        let dylibPath = binPath.appendingPathComponent("libPreviewSetup.dylib")
        try? fm.removeItem(at: dylibPath)

        let swiftcPath = try await resolveSwiftc()
        var args = ["-emit-library", "-o", dylibPath.path]
        args += ["-target", platform.targetTriple]
        if platform == .iOS {
            let sdkPath = try await resolveIOSSDK()
            args += ["-sdk", sdkPath]
        }

        let frameworks = collectFrameworks(binPath: binPath)
        if !frameworks.isEmpty {
            args += ["-F", binPath.path]
            for fw in frameworks {
                args += ["-framework", fw]
            }
        }

        args += allObjectFiles.map(\.path)

        let linkResult = try await runAsync(swiftcPath, arguments: args)
        guard linkResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: "setup dylib", stderr: linkResult.stderr
            )
        }

        // Ad-hoc codesign (required on Apple Silicon)
        let codesignPath = try await resolveCodesign()
        let signResult = try await runAsync(codesignPath, arguments: ["-s", "-", dylibPath.path])
        guard signResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: "setup dylib codesign", stderr: signResult.stderr
            )
        }

        return dylibPath
    }

    private static func collectObjectFiles(in directory: URL) -> [URL] {
        guard
            let enumerator = FileManager.default.enumerator(
                at: directory, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        else { return [] }
        var files: [URL] = []
        for case let url as URL in enumerator where url.pathExtension == "o" {
            files.append(url)
        }
        return files
    }

    private static func resolveSwiftc() async throws -> String {
        let result = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--find", "swiftc"], discardStderr: true
        )
        guard result.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: "swiftc", stderr: "Could not locate swiftc via xcrun"
            )
        }
        return result.stdout
    }

    private static func resolveCodesign() async throws -> String {
        let result = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--find", "codesign"], discardStderr: true
        )
        guard result.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: "codesign", stderr: "Could not locate codesign via xcrun"
            )
        }
        return result.stdout
    }

    private static func resolveIOSSDK() async throws -> String {
        let result = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--show-sdk-path", "--sdk", "iphonesimulator"]
        )
        guard result.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: "iOS SDK", stderr: result.stderr
            )
        }
        return result.stdout
    }

    private static func collectFrameworks(binPath: URL) -> [String] {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: binPath,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        return entries.compactMap { entry in
            let name = entry.lastPathComponent
            guard name.hasSuffix(".framework") else { return nil }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir),
                isDir.boolValue
            else { return nil }
            return String(name.dropLast(".framework".count))
        }
    }
}

public enum SetupBuilderError: Error, LocalizedError {
    case packageNotFound(String)
    case buildFailed(package: String, stderr: String)
    case moduleNotFound(String, searchPath: String)

    public var errorDescription: String? {
        switch self {
        case .packageNotFound(let path):
            return "Setup package not found at '\(path)'. Check the 'packagePath' in .previewsmcp.json."
        case .buildFailed(let pkg, let stderr):
            return "Setup package '\(pkg)' build failed:\n\(stderr)"
        case .moduleNotFound(let module, let searchPath):
            return
                "Setup module '\(module)' not found after build. Expected .swiftmodule at \(searchPath)."
        }
    }
}

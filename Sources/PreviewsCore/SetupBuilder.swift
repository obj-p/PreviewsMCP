import Foundation

/// Builds a setup plugin package and returns compiler flags for importing its module.
public enum SetupBuilder {

    public struct Result: Sendable {
        public let moduleName: String
        public let typeName: String
        public let compilerFlags: [String]
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

        let iosSDKPath: String? = platform == .iOS ? try await resolveIOSSDK() : nil

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

        // Archive .o files into .a libraries (SPM doesn't create archives for library targets)
        let archivedLibs = try await archiveTargets(binPath: binPath)

        var flags: [String] = [
            "-I", modulesDir.path,
        ]
        if !archivedLibs.isEmpty {
            flags += ["-L", binPath.path]
            for lib in archivedLibs {
                flags += ["-l\(lib)"]
            }
        }

        let frameworkNames = collectFrameworks(binPath: binPath)
        if !frameworkNames.isEmpty {
            flags += ["-F", binPath.path]
            for fw in frameworkNames {
                flags += ["-framework", fw]
            }
            flags += ["-Xlinker", "-rpath", "-Xlinker", binPath.path]
        }

        return Result(
            moduleName: config.moduleName,
            typeName: config.typeName,
            compilerFlags: flags
        )
    }

    /// Archive .o files from each target's build directory into .a static libraries.
    /// SPM leaves loose .o files under `<binPath>/<Target>.build/` without creating archives.
    private static func archiveTargets(binPath: URL) async throws -> [String] {
        let fm = FileManager.default
        guard
            let entries = try? fm.contentsOfDirectory(
                at: binPath, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }

        let arPath = try await resolveAr()
        var libs: [String] = []

        for entry in entries {
            let name = entry.lastPathComponent
            guard name.hasSuffix(".build") else { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else {
                continue
            }

            let targetName = String(name.dropLast(".build".count))
            if targetName.hasPrefix("_") { continue }

            let objectFiles = collectObjectFiles(in: entry)
            guard !objectFiles.isEmpty else { continue }

            let archivePath = binPath.appendingPathComponent("lib\(targetName).a")
            try? fm.removeItem(at: archivePath)

            var arArgs = ["rcs", archivePath.path]
            arArgs.append(contentsOf: objectFiles.map(\.path))
            let result = try await runAsync(arPath, arguments: arArgs)
            guard result.exitCode == 0 else {
                throw SetupBuilderError.buildFailed(
                    package: targetName, stderr: "ar failed: \(result.stderr)"
                )
            }
            libs.append(targetName)
        }
        return libs
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

    private static func resolveAr() async throws -> String {
        let result = try await runAsync(
            "/usr/bin/xcrun", arguments: ["--find", "ar"], discardStderr: true
        )
        guard result.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(package: "ar", stderr: "Could not locate ar via xcrun")
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

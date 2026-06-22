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
        /// SDK path used to compile the setup module. The downstream
        /// preview-bridge compile must inherit this SDK or swiftc will
        /// reject the swiftmodule with "cannot load module ... built with
        /// SDK 'macosxA' when using SDK 'macosxB'" (issue #170).
        public let sdkPath: String

        public init(
            moduleName: String,
            typeName: String,
            compilerFlags: [String],
            dylibPath: URL,
            sdkPath: String
        ) {
            self.moduleName = moduleName
            self.typeName = typeName
            self.compilerFlags = compilerFlags
            self.dylibPath = dylibPath
            self.sdkPath = sdkPath
        }
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

        // Concurrent builders of the same package coexist safely because
        // `linkDynamicLibrary` uses atomic rename — the on-disk
        // libPreviewSetup.dylib is never missing, so concurrent preview
        // compiles linking against it always find a valid file. Whichever
        // builder writes last wins; cache entries are idempotent per
        // source hash.

        // Resolve inputs for the cache key before checking the cache.
        // Pin the SDK both platforms — the swiftmodule SetupBuilder produces
        // gets imported by the downstream Compiler invocation, and a bare
        // `swift build` may otherwise pick a different SDK on hosts where
        // CommandLineTools and Xcode disagree (issue #170).
        let sdkPath = try await Toolchain.sdkPath(for: platform)
        let swiftVersion = try await SetupCache.resolveSwiftVersion()
        let sourceHash = try SetupCache.hashSources(
            packageDir: packageDir, sdkPath: sdkPath, swiftVersion: swiftVersion)

        if let cached = SetupCache.load(
            packageDir: packageDir,
            platform: platform,
            sourceHash: sourceHash,
            swiftVersion: swiftVersion
        ) {
            return cached
        }

        var buildArgs = ["build", "--package-path", packageDir.path, "--sdk", sdkPath]
        if platform == .iOS {
            buildArgs += ["--triple", PreviewPlatform.iOS.targetTriple]
        }

        let buildResult = try await SPMBuildRecovery.runSwift(
            arguments: buildArgs, workingDirectory: nil
        )
        guard buildResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: config.moduleName,
                stderr: buildResult.stderr.isEmpty ? buildResult.stdout : buildResult.stderr
            )
        }

        var binPathArgs = [
            "swift", "build", "--package-path", packageDir.path,
            "--show-bin-path", "--sdk", sdkPath,
        ]
        if platform == .iOS {
            binPathArgs += ["--triple", PreviewPlatform.iOS.targetTriple]
        }

        let binPathResult = try await runAsync("/usr/bin/env", arguments: binPathArgs)
        guard binPathResult.exitCode == 0 else {
            throw SetupBuilderError.buildFailed(
                package: config.moduleName, stderr: binPathResult.stderr
            )
        }

        let binPath = URL(fileURLWithPath: binPathResult.stdout)
        let modulesDir = binPath.appendingPathComponent("Modules")

        try BuildSystemSupport.verifySwiftModule(named: config.moduleName, in: modulesDir) {
            SetupBuilderError.moduleNotFound(config.moduleName, searchPath: modulesDir.path)
        }

        // Link .o files into a dynamic library so all preview dylibs share the same statics.
        // Static linking (.a) gives each preview dylib its own copy of statics, which breaks
        // setUp() state persistence across hot-reload cycles (see issue #86).
        let dylibPath = try await linkDynamicLibrary(binPath: binPath, platform: platform)

        var flags: [String] = [
            "-I", modulesDir.path,
            // Link against the setup dylib so the linker resolves setup symbols at link time.
            // At runtime the host pre-loads the dylib with RTLD_GLOBAL, so dyld reuses it
            // (matched by install_name). This is preferred over -undefined dynamic_lookup
            // which suppresses ALL undefined symbol errors, masking genuine problems.
            "-L", binPath.path, "-lPreviewSetup",
            // rpath so dyld can find libPreviewSetup.dylib when loading the preview dylib.
            "-Xlinker", "-rpath", "-Xlinker", binPath.path,
        ]

        let frameworkNames = BuildSystemSupport.collectFrameworks(binPath: binPath)
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
            dylibPath: dylibPath,
            sdkPath: sdkPath
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
                allObjectFiles.append(contentsOf: BuildSystemSupport.collectObjectFiles(in: entry))
            }
        }

        guard !allObjectFiles.isEmpty else {
            throw SetupBuilderError.buildFailed(
                package: "setup", stderr: "No object files found to link"
            )
        }

        // Remove stale static archives from previous builds so they don't confuse the linker.
        cleanStaleArchives(binPath: binPath)

        // Build to a temp path in the same directory, then atomically replace
        // the final dylib. Concurrent preview compiles that link against the
        // final path always see a valid file: either the old one (before
        // rename) or the new one (after rename), never a missing file.
        //
        // Keeping the install_name as the final path is critical — dyld
        // matches on install_name, not the on-disk path it was loaded from.
        let dylibPath = binPath.appendingPathComponent("libPreviewSetup.dylib")
        let tempDylib = binPath.appendingPathComponent(
            "libPreviewSetup.\(UUID().uuidString).dylib.tmp"
        )
        try? fm.removeItem(at: tempDylib)

        let swiftcPath = try await Toolchain.swiftcPath()
        var args = ["-emit-library", "-o", tempDylib.path]
        // Set the install name to the FINAL path (not the temp path). After
        // atomic rename, preview dylibs linked with this install_name will
        // find the file where dyld expects it.
        args += ["-Xlinker", "-install_name", "-Xlinker", dylibPath.path]
        args += ["-target", platform.targetTriple]

        // Always pass -sdk — swiftc needs it for both macOS and iOS to locate
        // the Swift runtime and system frameworks.
        let sdkPath = try await Toolchain.sdkPath(for: platform)
        args += ["-sdk", sdkPath]

        let frameworks = BuildSystemSupport.collectFrameworks(binPath: binPath)
        if !frameworks.isEmpty {
            args += ["-F", binPath.path]
            for fw in frameworks {
                args += ["-framework", fw]
            }
        }

        args += allObjectFiles.map(\.path)

        let linkResult = try await runAsync(swiftcPath, arguments: args)
        guard linkResult.exitCode == 0 else {
            try? fm.removeItem(at: tempDylib)
            throw SetupBuilderError.buildFailed(
                package: "setup dylib", stderr: linkResult.stderr
            )
        }

        // Ad-hoc codesign the temp file before it's visible at the final path
        // (required on Apple Silicon; dyld refuses unsigned dylibs).
        let codesignPath = try await Toolchain.codesignPath()
        let signResult = try await runAsync(codesignPath, arguments: ["-s", "-", tempDylib.path])
        guard signResult.exitCode == 0 else {
            try? fm.removeItem(at: tempDylib)
            throw SetupBuilderError.buildFailed(
                package: "setup dylib codesign", stderr: signResult.stderr
            )
        }

        // Atomic rename. On Darwin, rename(2) atomically replaces the target
        // if it exists — concurrent readers see either the old inode or the
        // new one. Never a window where the file is missing.
        guard rename(tempDylib.path, dylibPath.path) == 0 else {
            let reason = String(cString: strerror(errno))
            try? fm.removeItem(at: tempDylib)
            throw SetupBuilderError.buildFailed(
                package: "setup dylib rename",
                stderr: "rename(\(tempDylib.path) → \(dylibPath.path)) failed: \(reason)"
            )
        }

        return dylibPath
    }

    /// Remove stale artifacts from previous builds:
    /// - `.a` files from pre-dylib static-linking days
    /// - `libPreviewSetup.<UUID>.dylib.tmp` files leaked when a previous
    ///   builder crashed between `swiftc -emit-library` and the atomic
    ///   rename in `linkDynamicLibrary`.
    private static func cleanStaleArchives(binPath: URL) {
        guard
            let entries = try? FileManager.default.contentsOfDirectory(
                at: binPath, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
        else { return }
        for entry in entries {
            let name = entry.lastPathComponent
            let isLegacyArchive = entry.pathExtension == "a"
            let isLeakedTempDylib =
                name.hasPrefix("libPreviewSetup.") && name.hasSuffix(".dylib.tmp")
            if isLegacyArchive || isLeakedTempDylib {
                try? FileManager.default.removeItem(at: entry)
            }
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

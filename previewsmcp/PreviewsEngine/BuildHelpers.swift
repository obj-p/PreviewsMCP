import Foundation
import os
import PreviewsCore
import PreviewsIOS

/// CLI progress reporter that prints `[X/Y] message` to stderr.
public struct StderrProgressReporter: ProgressReporter {
    public let totalSteps: Int
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    public init(totalSteps: Int) {
        self.totalSteps = totalSteps
    }

    public func report(_: BuildPhase, message: String) async {
        let step = counter.withLock { value -> Int in
            value += 1
            return value
        }
        fputs("[\(step)/\(totalSteps)] \(message)\n", stderr)
    }

    public func tick(message: String, elapsed: Duration) async {
        let step = counter.withLock { $0 }
        fputs("[\(step)/\(totalSteps)] \(message) (\(elapsed.components.seconds)s)\n", stderr)
    }
}

/// Load project config from explicit path or auto-discover from source file directory.
public func loadProjectConfig(explicit configPath: String?, fileURL: URL) -> ProjectConfigLoader.Result? {
    if let configPath {
        let url = URL(fileURLWithPath: Path.normalize(configPath))
        let dir = url.deletingLastPathComponent()
        guard let data = try? Data(contentsOf: url),
              let config = try? JSONDecoder().decode(ProjectConfig.self, from: data)
        else {
            fputs("Warning: Could not load config from \(configPath)\n", stderr)
            return nil
        }
        return ProjectConfigLoader.Result(config: config, directory: dir)
    }
    return ProjectConfigLoader.find(from: fileURL.deletingLastPathComponent())
}

/// Build the setup package if configured in a ProjectConfig.
public func buildSetupFromConfig(
    _ configResult: ProjectConfigLoader.Result?,
    platform: PreviewPlatform
) async throws -> SetupBuilder.Result? {
    guard let setupConfig = configResult?.config.setup, let configDir = configResult?.directory
    else { return nil }
    return try await SetupBuilder.build(
        config: setupConfig, configDirectory: configDir, platform: platform
    )
}

/// Detect the build system for a source file and build it, reporting progress.
public func detectAndBuild(
    for fileURL: URL,
    projectRoot projectRootURL: URL?,
    platform: PreviewPlatform,
    scheme: String? = nil,
    buildSystem buildSystemOverride: BuildSystemKind? = nil,
    progress: (any ProgressReporter)? = nil
) async throws -> BuildContext? {
    await progress?.report(.detectingProject, message: "Detecting project...")
    guard
        let buildSystem = try await BuildSystemDetector.detect(
            for: fileURL, projectRoot: projectRootURL, scheme: scheme,
            buildSystem: buildSystemOverride
        )
    else {
        return nil
    }

    let buildSystemName = String(describing: type(of: buildSystem))
    Log.info("buildSystem: \(buildSystemName) projectRoot=\(buildSystem.projectRoot.path)")

    let platformLabel =
        platform == .iOS
            ? "Building for iOS (\(buildSystemName))..."
            : "Building (\(buildSystemName))..."
    return try await withPhase(progress, .buildingProject, platformLabel) {
        try await buildSystem.build(platform: platform)
    }
}

/// Resolve a simulator device UDID: provided > booted > first available.
public func resolveDeviceUDID(
    provided: String?,
    using simulatorManager: SimulatorManager
) async throws -> String {
    if let provided {
        return provided
    }
    // Prefer a supported (iOS 26+) simulator. A booted pre-26 device or older
    // installed runtimes must not be auto-picked, or the session would fail the
    // pre-26 gate (#282) even when a usable simulator is available.
    if let booted = try? await simulatorManager.findBootedDevice(), booted.isPreviewSupported {
        return booted.udid
    }
    let devices = try await simulatorManager.listDevices()
    guard let device = devices.first(where: { $0.isAvailable && $0.isPreviewSupported }) else {
        throw NoSimulatorError()
    }
    return device.udid
}

public struct NoSimulatorError: LocalizedError {
    public var errorDescription: String? {
        "No available iOS simulator devices found"
    }
}

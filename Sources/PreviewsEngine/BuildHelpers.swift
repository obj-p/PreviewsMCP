import Foundation
import PreviewsCore
import PreviewsIOS
import os

/// CLI progress reporter that prints `[X/Y] message` to stderr.
public struct StderrProgressReporter: ProgressReporter {
    public let totalSteps: Int
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    public init(totalSteps: Int) {
        self.totalSteps = totalSteps
    }

    public func report(_ phase: BuildPhase, message: String) async {
        let step = counter.withLock { value -> Int in
            value += 1
            return value
        }
        fputs("[\(step)/\(totalSteps)] \(message)\n", stderr)
    }
}

/// Load project config from explicit path or auto-discover from source file directory.
public func loadProjectConfig(explicit configPath: String?, fileURL: URL) -> ProjectConfigLoader.Result? {
    if let configPath {
        let url = URL(fileURLWithPath: configPath)
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
    progress: (any ProgressReporter)? = nil
) async throws -> BuildContext? {
    await progress?.report(.detectingProject, message: "Detecting project...")
    guard
        let buildSystem = try await BuildSystemDetector.detect(
            for: fileURL, projectRoot: projectRootURL, scheme: scheme
        )
    else {
        return nil
    }

    let platformLabel = platform == .iOS ? "Building for iOS..." : "Building..."
    await progress?.report(.buildingProject, message: platformLabel)

    let context = try await buildSystem.build(platform: platform)
    return context
}

/// Resolve a simulator device UDID: provided > booted > first available.
public func resolveDeviceUDID(
    provided: String?,
    using simulatorManager: SimulatorManager
) async throws -> String {
    if let provided {
        return provided
    }
    do {
        let booted = try await simulatorManager.findBootedDevice()
        return booted.udid
    } catch {
        let devices = try await simulatorManager.listDevices()
        guard let first = devices.first(where: { $0.isAvailable }) else {
            throw NoSimulatorError()
        }
        return first.udid
    }
}

public struct NoSimulatorError: Error, CustomStringConvertible {
    public var description: String { "No available iOS simulator devices found" }
}

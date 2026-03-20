import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS

/// Detect the build system for a source file and build it, logging progress to stderr.
func detectAndBuild(
    for fileURL: URL,
    projectRoot projectRootURL: URL?,
    platform: PreviewPlatform,
    logPrefix: String = ""
) async throws -> BuildContext? {
    guard let buildSystem = try await BuildSystemDetector.detect(
        for: fileURL, projectRoot: projectRootURL
    ) else {
        return nil
    }

    let prefix = logPrefix.isEmpty ? "" : "\(logPrefix) "
    let platformLabel = platform == .iOSSimulator ? "building for iOS..." : "building..."
    fputs("\(prefix)Detected project at \(buildSystem.projectRoot.path), \(platformLabel)\n", stderr)

    let context = try await buildSystem.build(platform: platform)
    fputs("\(prefix)Built target: \(context.targetName) (tier \(context.supportsTier2 ? "2" : "1"))\n", stderr)

    return context
}

/// Resolve a simulator device UDID: provided > booted > first available.
func resolveDeviceUDID(
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
            throw ValidationError("No available iOS simulator devices found")
        }
        return first.udid
    }
}


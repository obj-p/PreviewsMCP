import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS
import os

/// CLI progress reporter that prints `[X/Y] message` to stderr.
struct StderrProgressReporter: ProgressReporter {
    let totalSteps: Int
    private let counter = OSAllocatedUnfairLock(initialState: 0)

    func report(_ phase: BuildPhase, message: String) async {
        let step = counter.withLock { value -> Int in
            value += 1
            return value
        }
        fputs("[\(step)/\(totalSteps)] \(message)\n", stderr)
    }
}

/// Detect the build system for a source file and build it, reporting progress.
func detectAndBuild(
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

/// Compile and display a macOS SwiftUI preview window with file watching.
func launchMacOSPreview(
    fileURL: URL,
    previewIndex: Int,
    title: String,
    width: Int,
    height: Int,
    buildContext: BuildContext?,
    traits: PreviewTraits = PreviewTraits(),
    progress: (any ProgressReporter)? = nil
) async throws {
    let compiler = try await Compiler()

    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: compiler,
        buildContext: buildContext,
        traits: traits
    )

    await progress?.report(.compilingBridge, message: "Compiling \(fileURL.lastPathComponent)...")
    let compileResult = try await session.compile()

    await MainActor.run {
        do {
            try App.host.loadPreview(
                sessionID: session.id,
                dylibPath: compileResult.dylibPath,
                title: title,
                size: NSSize(width: width, height: height)
            )
            App.host.watchFile(
                sessionID: session.id,
                session: session,
                filePath: fileURL.path,
                compiler: compiler,
                additionalPaths: buildContext?.sourceFiles?.map(\.path) ?? [],
                buildContext: buildContext
            )
            fputs("Preview is live! Watching for changes...\n", stderr)
        } catch {
            fputs("Failed to load preview: \(error)\n", stderr)
            NSApp.terminate(nil)
        }
    }
}

/// Launch an iOS simulator preview with file watching.
func launchIOSPreview(
    fileURL: URL,
    previewIndex: Int,
    deviceUDID: String?,
    headless: Bool = false,
    buildContext: BuildContext?,
    traits: PreviewTraits = PreviewTraits(),
    progress: (any ProgressReporter)? = nil
) async throws {
    let compiler = try await Compiler(platform: .iOS)
    let hostBuilder = try await IOSHostBuilder()
    let simulatorManager = SimulatorManager()

    let udid = try await resolveDeviceUDID(provided: deviceUDID, using: simulatorManager)

    let session = IOSPreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        deviceUDID: udid,
        compiler: compiler,
        hostBuilder: hostBuilder,
        simulatorManager: simulatorManager,
        headless: headless,
        buildContext: buildContext,
        traits: traits,
        progress: progress
    )

    _ = try await session.start()
    fputs("Preview is live! Watching for changes...\n", stderr)

    let allPaths = [fileURL.path] + (buildContext?.sourceFiles?.map(\.path) ?? [])
    let watcher = try? FileWatcher(paths: allPaths) {
        Task {
            do {
                let wasLiteralOnly = try await session.handleSourceChange()
                if wasLiteralOnly {
                    fputs("Literal-only change applied (state preserved)\n", stderr)
                } else {
                    fputs("Structural change — recompiled\n", stderr)
                }
            } catch {
                fputs("Reload failed: \(error)\n", stderr)
            }
        }
    }
    _ = watcher
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

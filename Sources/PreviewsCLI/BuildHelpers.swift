import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

/// Detect the build system for a source file and build it, logging progress to stderr.
func detectAndBuild(
    for fileURL: URL,
    projectRoot projectRootURL: URL?,
    platform: PreviewPlatform,
    logPrefix: String = ""
) async throws -> BuildContext? {
    guard
        let buildSystem = try await BuildSystemDetector.detect(
            for: fileURL, projectRoot: projectRootURL
        )
    else {
        return nil
    }

    let prefix = logPrefix.isEmpty ? "" : "\(logPrefix) "
    let platformLabel = platform == .iOSSimulator ? "building for iOS..." : "building..."
    fputs("\(prefix)Detected project at \(buildSystem.projectRoot.path), \(platformLabel)\n", stderr)

    let context = try await buildSystem.build(platform: platform)
    fputs("\(prefix)Built target: \(context.targetName) (tier \(context.supportsTier2 ? "2" : "1"))\n", stderr)

    return context
}

let defaultPlaygroundCode = """
    import SwiftUI

    struct PlaygroundView: View {
        var body: some View {
            VStack {
                Text("Hello, playground!")
                    .font(.title)
            }
            .padding()
        }
    }

    #Preview {
        PlaygroundView()
    }
    """

/// Create a playground Swift file, returning its URL.
/// When `at` is provided, writes to that path (creating parent directories).
/// Otherwise creates a temp file with a unique name.
func createPlaygroundFile(code: String? = nil, at outputPath: URL? = nil) throws -> URL {
    let fileURL: URL
    if let outputPath {
        let dir = outputPath.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        fileURL = outputPath
    } else {
        let playgroundDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-playground", isDirectory: true)
        try FileManager.default.createDirectory(at: playgroundDir, withIntermediateDirectories: true)
        let shortID = UUID().uuidString.prefix(8)
        fileURL = playgroundDir.appendingPathComponent("Playground_\(shortID).swift")
    }

    try (code ?? defaultPlaygroundCode).write(to: fileURL, atomically: true, encoding: .utf8)
    return fileURL
}

/// Compile and display a macOS SwiftUI preview window with file watching.
func launchMacOSPreview(
    fileURL: URL,
    previewIndex: Int,
    title: String,
    width: Int,
    height: Int,
    buildContext: BuildContext?
) async throws {
    let compiler = try await Compiler()

    let session = PreviewSession(
        sourceFile: fileURL,
        previewIndex: previewIndex,
        compiler: compiler,
        buildContext: buildContext
    )

    fputs("Compiling \(fileURL.lastPathComponent)...\n", stderr)
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
                previewIndex: previewIndex,
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
    buildContext: BuildContext?
) async throws {
    let compiler = try await Compiler(platform: .iOSSimulator)
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
        headless: true,
        buildContext: buildContext
    )

    fputs("Launching on simulator \(udid)...\n", stderr)
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

import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Compile a SwiftUI preview and save a screenshot"
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String

    @Option(name: .shortAndLong, help: "Output image file path (.jpg or .png)")
    var output: String = "preview.jpg"

    @Option(name: .long, help: "Which preview to snapshot (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' (default) or 'ios'")
    var platform: CLIPlatform = .macos

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(
        name: .long,
        help: "Xcode scheme name (only for .xcodeproj / .xcworkspace projects with multiple schemes)"
    )
    var scheme: String?

    @Option(name: .long, help: "Simulator device UDID (for ios; auto-selects if omitted)")
    var device: String?

    @Option(name: .long, help: "Color scheme: 'light' or 'dark'")
    var colorScheme: String?

    @Option(name: .long, help: "Dynamic Type size (e.g., 'large', 'accessibility3')")
    var dynamicTypeSize: String?

    @Option(name: .long, help: "Locale identifier (e.g., 'en', 'ar', 'ja-JP')")
    var locale: String?

    @Option(name: .long, help: "Layout direction: 'leftToRight' or 'rightToLeft'")
    var layoutDirection: String?

    @Option(name: .long, help: "Legibility weight: 'regular' or 'bold'")
    var legibilityWeight: String?

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        let projectConfig = loadProjectConfig(explicit: config, fileURL: fileURL)

        do {
            _ = try PreviewTraits.validated(
                colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
                locale: locale, layoutDirection: layoutDirection,
                legibilityWeight: legibilityWeight
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        let resolvedPlatform: CLIPlatform = {
            if platform != .macos { return platform }
            if let cp = projectConfig?.platform, cp == "ios" { return .ios }
            return platform
        }()

        switch resolvedPlatform {
        case .ios:
            runIOSSnapshot(fileURL: fileURL, projectConfig: projectConfig)
        case .macos:
            runMacOSSnapshot(fileURL: fileURL, projectConfig: projectConfig)
        }
    }

    private func runMacOSSnapshot(fileURL: URL, projectConfig: ProjectConfig?) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let outputURL = URL(fileURLWithPath: output)
        let projectPath = project
        let schemeName = scheme
        let configTraits = projectConfig?.traits?.toPreviewTraits() ?? PreviewTraits()
        let explicitTraits = PreviewTraits(
            colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
            locale: locale, layoutDirection: layoutDirection,
            legibilityWeight: legibilityWeight
        )
        let traits = configTraits.merged(with: explicitTraits)
        let progress: any ProgressReporter = StderrProgressReporter(totalSteps: 4)

        Task {
            do {
                let compiler = try await Compiler()

                // Detect build system
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL,
                    projectRoot: projectRootURL,
                    platform: .macOS,
                    scheme: schemeName,
                    progress: progress)

                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler,
                    buildContext: buildContext,
                    traits: traits,
                    setupModule: projectConfig?.setup?.moduleName,
                    setupType: projectConfig?.setup?.typeName
                )

                await progress.report(
                    .compilingBridge, message: "Compiling \(fileURL.lastPathComponent)...")
                let compileResult = try await session.compile()
                let sessionID = session.id

                await MainActor.run {
                    do {
                        try App.host.loadPreview(
                            sessionID: sessionID,
                            dylibPath: compileResult.dylibPath,
                            title: "Snapshot",
                            size: NSSize(width: windowWidth, height: windowHeight)
                        )
                    } catch {
                        fputs("Failed to load preview: \(error)\n", stderr)
                        NSApp.terminate(nil)
                    }
                }

                // Wait for SwiftUI to lay out
                try await Task.sleep(for: .milliseconds(500))

                await progress.report(.capturingSnapshot, message: "Capturing snapshot...")
                let snapshotFormat: Snapshot.ImageFormat =
                    outputURL.pathExtension.lowercased() == "png" ? .png : .jpeg(quality: 0.85)
                await MainActor.run {
                    do {
                        guard let window = App.host.window(for: sessionID) else {
                            fputs("No window found\n", stderr)
                            NSApp.terminate(nil)
                            return
                        }
                        try Snapshot.capture(window: window, format: snapshotFormat, to: outputURL)
                        print(outputURL.path)
                    } catch {
                        fputs("Snapshot failed: \(error)\n", stderr)
                    }
                    NSApp.terminate(nil)
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
    }

    private func runIOSSnapshot(fileURL: URL, projectConfig: ProjectConfig?) {
        let previewIndex = preview
        let outputURL = URL(fileURLWithPath: output)
        let deviceUDID = device ?? projectConfig?.device
        let projectPath = project
        let schemeName = scheme
        let configTraits = projectConfig?.traits?.toPreviewTraits() ?? PreviewTraits()
        let explicitTraits = PreviewTraits(
            colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
            locale: locale, layoutDirection: layoutDirection,
            legibilityWeight: legibilityWeight
        )
        let traits = configTraits.merged(with: explicitTraits)
        let progress: any ProgressReporter = StderrProgressReporter(totalSteps: 9)

        Task {
            do {
                let compiler = try await Compiler(platform: .iOS)
                let hostBuilder = try await IOSHostBuilder()
                let simulatorManager = SimulatorManager()

                // Resolve device
                let udid = try await resolveDeviceUDID(provided: deviceUDID, using: simulatorManager)

                // Detect build system
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL,
                    projectRoot: projectRootURL,
                    platform: .iOS,
                    scheme: schemeName,
                    progress: progress)

                let session = IOSPreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: udid,
                    compiler: compiler,
                    hostBuilder: hostBuilder,
                    simulatorManager: simulatorManager,
                    headless: true,
                    buildContext: buildContext,
                    traits: traits,
                    setupModule: projectConfig?.setup?.moduleName,
                    setupType: projectConfig?.setup?.typeName,
                    progress: progress
                )

                _ = try await session.start()

                // Wait for the app to render
                try await Task.sleep(for: .seconds(2))

                await progress.report(.capturingSnapshot, message: "Capturing snapshot...")
                let jpegQuality: Double = outputURL.pathExtension.lowercased() == "png" ? 1.0 : 0.85
                let imageData = try await session.screenshot(jpegQuality: jpegQuality)
                try imageData.write(to: outputURL)
                print(outputURL.path)

                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                fputs("Error: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
    }
}

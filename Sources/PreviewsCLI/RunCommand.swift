import AppKit
import ArgumentParser
import Foundation
import PreviewsCore

struct RunCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "run",
        abstract: "Compile and display a live SwiftUI preview"
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String

    @Option(name: .long, help: "Which preview to show (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' or 'ios' (auto-detected if omitted)")
    var platform: CLIPlatform?

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

    @Flag(name: .long, help: "Hide Simulator.app GUI (iOS only)")
    var headless: Bool = false

    @Option(name: .long, help: "Path to .previewsmcp.json config file (auto-discovered if omitted)")
    var config: String?

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        let configResult = loadProjectConfig(explicit: config, fileURL: fileURL)
        let projectConfig = configResult?.config

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
            if let explicit = platform { return explicit }
            if let cp = projectConfig?.platform { return cp == "ios" ? .ios : .macos }
            if SPMBuildSystem.inferredPlatform(for: fileURL) == .iOS {
                return .ios
            }
            return .macos
        }()

        switch resolvedPlatform {
        case .ios:
            runIOS(fileURL: fileURL, configResult: configResult)
        case .macos:
            runMacOS(fileURL: fileURL, configResult: configResult)
        }
    }

    private func runMacOS(fileURL: URL, configResult: ProjectConfigLoader.Result?) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let projectPath = project
        let schemeName = scheme
        let configTraits = configResult?.config.traits?.toPreviewTraits() ?? PreviewTraits()
        let explicitTraits = PreviewTraits(
            colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
            locale: locale, layoutDirection: layoutDirection,
            legibilityWeight: legibilityWeight
        )
        let traits = configTraits.merged(with: explicitTraits)
        let progress: any ProgressReporter = StderrProgressReporter(totalSteps: 3)

        Task {
            do {
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL,
                    projectRoot: projectRootURL,
                    platform: .macOS,
                    scheme: schemeName,
                    progress: progress)

                let setupResult = try await buildSetupFromConfig(configResult, platform: .macOS)

                try await launchMacOSPreview(
                    fileURL: fileURL,
                    previewIndex: previewIndex,
                    title: "Preview: \(fileURL.lastPathComponent)",
                    width: windowWidth,
                    height: windowHeight,
                    buildContext: buildContext,
                    traits: traits,
                    setupResult: setupResult,
                    progress: progress
                )
            } catch {
                fputs("Error: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
    }

    private func runIOS(fileURL: URL, configResult: ProjectConfigLoader.Result?) {
        let previewIndex = preview
        let deviceUDID = device ?? configResult?.config.device
        let projectPath = project
        let schemeName = scheme
        let configTraits = configResult?.config.traits?.toPreviewTraits() ?? PreviewTraits()
        let explicitTraits = PreviewTraits(
            colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize,
            locale: locale, layoutDirection: layoutDirection,
            legibilityWeight: legibilityWeight
        )
        let traits = configTraits.merged(with: explicitTraits)
        let isHeadless = headless
        let progress: any ProgressReporter = StderrProgressReporter(totalSteps: 8)

        Task {
            do {
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL,
                    projectRoot: projectRootURL,
                    platform: .iOS,
                    scheme: schemeName,
                    progress: progress)

                let setupResult = try await buildSetupFromConfig(configResult, platform: .iOS)

                try await launchIOSPreview(
                    fileURL: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: deviceUDID,
                    headless: isHeadless,
                    buildContext: buildContext,
                    traits: traits,
                    setupResult: setupResult,
                    progress: progress
                )
            } catch {
                fputs("Error: \(error)\n", stderr)
                Darwin.exit(1)
            }
        }
    }
}

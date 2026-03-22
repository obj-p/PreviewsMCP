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

    @Option(name: .long, help: "Target platform: 'macos' (default) or 'ios-simulator'")
    var platform: CLIPlatform = .macos

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(name: .long, help: "Simulator device UDID (for ios-simulator; auto-selects if omitted)")
    var device: String?

    @Option(name: .long, help: "Color scheme: 'light' or 'dark'")
    var colorScheme: String?

    @Option(name: .long, help: "Dynamic Type size (e.g., 'large', 'accessibility3')")
    var dynamicTypeSize: String?

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        if let cs = colorScheme, !PreviewTraits.validColorSchemes.contains(cs) {
            throw ValidationError(
                "Invalid color scheme '\(cs)'. Must be 'light' or 'dark'.")
        }
        if let dts = dynamicTypeSize, !PreviewTraits.validDynamicTypeSizes.contains(dts) {
            throw ValidationError(
                "Invalid dynamic type size '\(dts)'. Valid values: \(PreviewTraits.validDynamicTypeSizes.sorted().joined(separator: ", "))"
            )
        }

        switch platform {
        case .iosSimulator:
            runIOS(fileURL: fileURL)
        case .macos:
            runMacOS(fileURL: fileURL)
        }
    }

    private func runMacOS(fileURL: URL) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let projectPath = project
        let traits = PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)

        Task {
            do {
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .macOS)

                try await launchMacOSPreview(
                    fileURL: fileURL,
                    previewIndex: previewIndex,
                    title: "Preview: \(fileURL.lastPathComponent)",
                    width: windowWidth,
                    height: windowHeight,
                    buildContext: buildContext,
                    traits: traits
                )
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    private func runIOS(fileURL: URL) {
        let previewIndex = preview
        let deviceUDID = device
        let projectPath = project
        let traits = PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)

        Task {
            do {
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(
                    for: fileURL, projectRoot: projectRootURL, platform: .iOSSimulator)

                try await launchIOSPreview(
                    fileURL: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: deviceUDID,
                    buildContext: buildContext,
                    traits: traits
                )
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

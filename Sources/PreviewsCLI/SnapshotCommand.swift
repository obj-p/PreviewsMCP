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

    @Option(name: .long, help: "Simulator device UDID (for ios; auto-selects if omitted)")
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

        do {
            _ = try PreviewTraits.validated(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        switch platform {
        case .ios:
            runIOSSnapshot(fileURL: fileURL)
        case .macos:
            runMacOSSnapshot(fileURL: fileURL)
        }
    }

    private func runMacOSSnapshot(fileURL: URL) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let outputURL = URL(fileURLWithPath: output)
        let projectPath = project
        let traits = PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)

        Task {
            do {
                let compiler = try await Compiler()

                // Detect build system
                let projectRootURL = projectPath.map { URL(fileURLWithPath: $0) }
                let buildContext = try await detectAndBuild(for: fileURL, projectRoot: projectRootURL, platform: .macOS)

                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler,
                    buildContext: buildContext,
                    traits: traits
                )

                fputs("Compiling \(fileURL.lastPathComponent)...\n", stderr)
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
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    private func runIOSSnapshot(fileURL: URL) {
        let previewIndex = preview
        let outputURL = URL(fileURLWithPath: output)
        let deviceUDID = device
        let projectPath = project
        let traits = PreviewTraits(colorScheme: colorScheme, dynamicTypeSize: dynamicTypeSize)

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
                    for: fileURL, projectRoot: projectRootURL, platform: .iOS)

                let session = IOSPreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    deviceUDID: udid,
                    compiler: compiler,
                    hostBuilder: hostBuilder,
                    simulatorManager: simulatorManager,
                    headless: true,
                    buildContext: buildContext,
                    traits: traits
                )

                fputs("Compiling and launching on simulator \(udid)...\n", stderr)
                _ = try await session.start()

                // Wait for the app to render
                try await Task.sleep(for: .seconds(2))

                let jpegQuality: Double = outputURL.pathExtension.lowercased() == "png" ? 1.0 : 0.85
                let imageData = try await session.screenshot(jpegQuality: jpegQuality)
                try imageData.write(to: outputURL)
                print(outputURL.path)

                await MainActor.run { NSApp.terminate(nil) }
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsMacOS
import PreviewsIOS

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
    var platform: String = "macos"

    @Option(name: .long, help: "Project root path (auto-detected if omitted)")
    var project: String?

    @Option(name: .long, help: "Simulator device UDID (for ios-simulator; auto-selects if omitted)")
    var device: String?

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        if platform == "ios-simulator" {
            runIOS(fileURL: fileURL)
        } else {
            runMacOS(fileURL: fileURL)
        }
    }

    private func runMacOS(fileURL: URL) {
        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height

        Task {
            do {
                let compiler = try await Compiler()

                // Detect build system
                let buildContext: BuildContext?
                if let buildSystem = try await BuildSystemDetector.detect(for: fileURL) {
                    fputs("Detected project at \(buildSystem.projectRoot.path), building...\n", stderr)
                    let ctx = try await buildSystem.build(platform: .macOS)
                    fputs("Built target: \(ctx.targetName) (tier \(ctx.supportsTier2 ? "2" : "1"))\n", stderr)
                    buildContext = ctx
                } else {
                    buildContext = nil
                }

                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler,
                    buildContext: buildContext
                )

                fputs("Compiling \(fileURL.lastPathComponent)...\n", stderr)
                let compileResult = try await session.compile()
                fputs("Compiled: \(compileResult.dylibPath.lastPathComponent)\n", stderr)

                await MainActor.run {
                    do {
                        try App.host.loadPreview(
                            sessionID: session.id,
                            dylibPath: compileResult.dylibPath,
                            title: "Preview: \(fileURL.lastPathComponent)",
                            size: NSSize(width: windowWidth, height: windowHeight)
                        )
                        App.host.watchFile(
                            sessionID: session.id,
                            session: session,
                            filePath: fileURL.path,
                            compiler: compiler,
                            previewIndex: previewIndex
                        )
                        fputs("Preview is live! Watching for changes...\n", stderr)
                    } catch {
                        fputs("Failed to load preview: \(error)\n", stderr)
                        NSApp.terminate(nil)
                    }
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }

    private func runIOS(fileURL: URL) {
        let previewIndex = preview
        let deviceUDID = device

        Task {
            do {
                let compiler = try await Compiler(platform: .iOSSimulator)
                let hostBuilder = try await IOSHostBuilder()
                let simulatorManager = SimulatorManager()

                // Resolve device
                let udid: String
                if let provided = deviceUDID {
                    udid = provided
                } else {
                    do {
                        let booted = try await simulatorManager.findBootedDevice()
                        udid = booted.udid
                    } catch {
                        let devices = try await simulatorManager.listDevices()
                        guard let first = devices.first(where: { $0.isAvailable }) else {
                            throw ValidationError("No available iOS simulator devices found")
                        }
                        udid = first.udid
                    }
                }

                // Detect build system
                let buildContext: BuildContext?
                if let buildSystem = try await BuildSystemDetector.detect(for: fileURL) {
                    fputs("Detected project at \(buildSystem.projectRoot.path), building for iOS...\n", stderr)
                    let ctx = try await buildSystem.build(platform: .iOSSimulator)
                    fputs("Built target: \(ctx.targetName) (tier \(ctx.supportsTier2 ? "2" : "1"))\n", stderr)
                    buildContext = ctx
                } else {
                    buildContext = nil
                }

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

                fputs("Launching preview on simulator \(udid)...\n", stderr)
                _ = try await session.start()
                fputs("iOS preview is live!\n", stderr)

                // Keep running (NSApp run loop keeps the process alive)
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

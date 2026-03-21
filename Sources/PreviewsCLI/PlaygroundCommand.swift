import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

struct PlaygroundCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playground",
        abstract: "Create a temporary SwiftUI file and start a live preview"
    )

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' (default) or 'ios-simulator'")
    var platform: CLIPlatform = .macos

    @Option(name: .long, help: "Simulator device UDID (for ios-simulator; auto-selects if omitted)")
    var device: String?

    mutating func run() throws {
        // Create temp file with default skeleton
        let playgroundDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-playground", isDirectory: true)
        try FileManager.default.createDirectory(
            at: playgroundDir, withIntermediateDirectories: true)

        let shortID = UUID().uuidString.prefix(8)
        let fileName = "Playground_\(shortID).swift"
        let fileURL = playgroundDir.appendingPathComponent(fileName)
        try defaultPlaygroundCode.write(to: fileURL, atomically: true, encoding: .utf8)

        fputs("Playground file: \(fileURL.path)\n", stderr)
        fputs("Edit this file to see live changes.\n", stderr)

        switch platform {
        case .iosSimulator:
            runIOS(fileURL: fileURL)
        case .macos:
            runMacOS(fileURL: fileURL)
        }
    }

    private func runMacOS(fileURL: URL) {
        let windowWidth = width
        let windowHeight = height

        Task {
            do {
                let compiler = try await Compiler()

                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: 0,
                    compiler: compiler,
                    buildContext: nil
                )

                fputs("Compiling \(fileURL.lastPathComponent)...\n", stderr)
                let compileResult = try await session.compile()

                await MainActor.run {
                    do {
                        try App.host.loadPreview(
                            sessionID: session.id,
                            dylibPath: compileResult.dylibPath,
                            title: "Playground: \(fileURL.lastPathComponent)",
                            size: NSSize(width: windowWidth, height: windowHeight)
                        )
                        App.host.watchFile(
                            sessionID: session.id,
                            session: session,
                            filePath: fileURL.path,
                            compiler: compiler,
                            previewIndex: 0,
                            additionalPaths: [],
                            buildContext: nil
                        )
                        fputs("Playground is live! Watching for changes...\n", stderr)
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
        let deviceUDID = device

        Task {
            do {
                let compiler = try await Compiler(platform: .iOSSimulator)
                let hostBuilder = try await IOSHostBuilder()
                let simulatorManager = SimulatorManager()

                let udid = try await resolveDeviceUDID(provided: deviceUDID, using: simulatorManager)

                let session = IOSPreviewSession(
                    sourceFile: fileURL,
                    previewIndex: 0,
                    deviceUDID: udid,
                    compiler: compiler,
                    hostBuilder: hostBuilder,
                    simulatorManager: simulatorManager,
                    headless: true,
                    buildContext: nil
                )

                fputs("Launching playground on simulator \(udid)...\n", stderr)
                _ = try await session.start()
                fputs("iOS playground is live! Watching for changes...\n", stderr)

                let watcher = try? FileWatcher(paths: [fileURL.path]) {
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
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

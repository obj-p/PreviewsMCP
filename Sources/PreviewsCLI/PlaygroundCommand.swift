import AppKit
import ArgumentParser
import Foundation

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
        let fileURL = try createPlaygroundFile()

        fputs("Playground file: \(fileURL.path)\n", stderr)
        fputs("Edit this file to see live changes.\n", stderr)

        let windowWidth = width
        let windowHeight = height
        let deviceUDID = device
        let targetPlatform = platform

        Task {
            do {
                switch targetPlatform {
                case .macos:
                    try await launchMacOSPreview(
                        fileURL: fileURL,
                        previewIndex: 0,
                        title: "Playground: \(fileURL.lastPathComponent)",
                        width: windowWidth,
                        height: windowHeight,
                        buildContext: nil
                    )
                case .iosSimulator:
                    try await launchIOSPreview(
                        fileURL: fileURL,
                        previewIndex: 0,
                        deviceUDID: deviceUDID,
                        buildContext: nil
                    )
                }
            } catch {
                fputs("Error: \(error)\n", stderr)
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

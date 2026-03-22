import AppKit
import ArgumentParser
import Foundation

struct PlaygroundCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "playground",
        abstract: "Scaffold a new SwiftUI file and start a live preview"
    )

    @Argument(help: "Output path for the new file (creates a temp file if omitted)")
    var file: String?

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    @Option(name: .long, help: "Target platform: 'macos' (default) or 'ios-simulator'")
    var platform: CLIPlatform = .macos

    @Option(name: .long, help: "Simulator device UDID (for ios-simulator; auto-selects if omitted)")
    var device: String?

    mutating func run() throws {
        let fileURL: URL
        if let file {
            let url = URL(fileURLWithPath: file).standardizedFileURL
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) {
                if isDir.boolValue {
                    throw ValidationError(
                        "'\(file)' is a directory. Provide a file path, e.g. '\(file)/MyView.swift'")
                }
                throw ValidationError(
                    "File already exists: \(file). Use 'previewsmcp run \(file)' to preview it.")
            }
            fileURL = try createPlaygroundFile(at: url)
        } else {
            fileURL = try createPlaygroundFile()
        }

        print(fileURL.path)
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

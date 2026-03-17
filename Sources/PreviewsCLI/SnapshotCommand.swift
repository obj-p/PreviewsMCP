import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewHost

struct SnapshotCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "snapshot",
        abstract: "Compile a SwiftUI preview and save a screenshot"
    )

    @Argument(help: "Path to Swift source file containing #Preview")
    var file: String

    @Option(name: .shortAndLong, help: "Output PNG file path")
    var output: String = "preview.png"

    @Option(name: .long, help: "Which preview to snapshot (0-based index)")
    var preview: Int = 0

    @Option(name: .long, help: "Window width")
    var width: Int = 400

    @Option(name: .long, help: "Window height")
    var height: Int = 600

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height
        let outputURL = URL(fileURLWithPath: output)

        Task {
            do {
                let compiler = try await Compiler()
                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler
                )

                print("Compiling \(fileURL.lastPathComponent)...")
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
                        print("Failed to load preview: \(error)")
                        NSApp.terminate(nil)
                    }
                }

                // Wait for SwiftUI to lay out
                try await Task.sleep(for: .milliseconds(500))

                await MainActor.run {
                    do {
                        guard let window = App.host.window(for: sessionID) else {
                            print("No window found")
                            NSApp.terminate(nil)
                            return
                        }
                        try Snapshot.capture(window: window, to: outputURL)
                        print("Snapshot saved to: \(outputURL.path)")
                    } catch {
                        print("Snapshot failed: \(error)")
                    }
                    NSApp.terminate(nil)
                }
            } catch {
                print("Error: \(error)")
                await MainActor.run { NSApp.terminate(nil) }
            }
        }
    }
}

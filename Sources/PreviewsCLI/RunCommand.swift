import AppKit
import ArgumentParser
import Foundation
import PreviewsCore
import PreviewHost

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

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ValidationError("File not found: \(file)")
        }

        let previewIndex = preview
        let windowWidth = width
        let windowHeight = height

        Task {
            do {
                let compiler = try await Compiler()
                let session = PreviewSession(
                    sourceFile: fileURL,
                    previewIndex: previewIndex,
                    compiler: compiler
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
}

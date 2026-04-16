import ArgumentParser
import Foundation
import PreviewsCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List #Preview blocks in a Swift source file"
    )

    @Argument(help: "Path to Swift source file")
    var file: String

    @Flag(
        name: .long,
        help: "Emit preview info as a JSON document on stdout"
    )
    var json: Bool = false

    mutating func run() throws {
        let fileURL = URL(fileURLWithPath: file).standardizedFileURL
        let previews = try PreviewParser.parse(fileAt: fileURL)

        if json {
            let payload = DaemonProtocol.PreviewListResult(
                file: fileURL.path,
                previews: previews.map {
                    DaemonProtocol.PreviewInfoDTO(from: $0, activeIndex: -1)
                }
            )
            try emitJSON(payload)
            return
        }

        if previews.isEmpty {
            print("No #Preview blocks found in \(fileURL.lastPathComponent)")
            return
        }

        for preview in previews {
            let name = preview.name ?? "Preview"
            print("[\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)")
        }
    }
}

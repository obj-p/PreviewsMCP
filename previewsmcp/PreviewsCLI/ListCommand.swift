import ArgumentParser
import Foundation
import PreviewsCore

struct ListCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "list",
        abstract: "List #Preview blocks in a Swift source file or directory"
    )

    @Argument(
        help: "Path to a Swift source file or directory to scan",
        transform: Path.normalize
    )
    var path: String

    @Flag(
        name: .long,
        help: "Stream one JSON object per preview (NDJSON) on stdout"
    )
    var json: Bool = false

    func validate() throws {
        guard !path.isEmpty else {
            throw ValidationError("path must not be empty")
        }
        guard FileManager.default.fileExists(atPath: path) else {
            throw ValidationError("path does not exist: \(path)")
        }
    }

    func run() throws {
        var isDirectory: ObjCBool = false
        FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
        let files = isDirectory.boolValue ? Self.swiftFiles(in: path) : [path]

        var total = 0
        var failures = 0
        for file in files {
            let previews: [PreviewInfo]
            do {
                previews = try PreviewParser.parse(fileAt: URL(fileURLWithPath: file))
            } catch {
                warn("warning: skipping \(file): \(error.localizedDescription)")
                failures += 1
                continue
            }

            if json {
                for preview in previews {
                    try emitJSONLine(PreviewLine(from: preview, file: file))
                }
            } else if isDirectory.boolValue {
                guard !previews.isEmpty else { continue }
                print(file)
                for preview in previews {
                    print("  " + Self.humanLine(preview))
                }
            } else if previews.isEmpty {
                print("No #Preview blocks found in \(URL(fileURLWithPath: file).lastPathComponent)")
            } else {
                for preview in previews {
                    print(Self.humanLine(preview))
                }
            }
            total += previews.count
        }

        if isDirectory.boolValue {
            warn("scanned \(files.count) files, \(failures) failures, \(total) previews")
        }
        if failures > 0 {
            throw ExitCode.failure
        }
    }
}

struct PreviewLine: Encodable {
    let file: String
    let index: Int
    let name: String?
    let line: Int
    let snippet: String

    init(from preview: PreviewInfo, file: String) {
        self.file = file
        index = preview.index
        name = preview.name
        line = preview.line
        snippet = preview.snippet
    }
}

extension ListCommand {
    static func swiftFiles(in path: String) -> [String] {
        let url = URL(fileURLWithPath: path)
        guard
            let enumerator = FileManager.default.enumerator(
                at: url,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )
        else { return [] }
        return
            enumerator
                .compactMap { $0 as? URL }
                .filter { $0.pathExtension == "swift" }
                .map(\.path)
                .sorted()
    }

    static func humanLine(_ preview: PreviewInfo) -> String {
        let name = preview.name ?? "Preview"
        return "[\(preview.index)] \(name) (line \(preview.line)): \(preview.snippet)"
    }
}

private extension ListCommand {
    func emitJSONLine(_ record: PreviewLine) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(record)
        data.append(0x0A)
        FileHandle.standardOutput.write(data)
    }

    func warn(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }
}

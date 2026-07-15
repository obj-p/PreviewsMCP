import Foundation

guard let outputPath = CommandLine.arguments.dropFirst().first else {
    fatalError("FixtureCodegen expects an output file")
}

let outputURL = URL(fileURLWithPath: outputPath)
try FileManager.default.createDirectory(
    at: outputURL.deletingLastPathComponent(),
    withIntermediateDirectories: true
)

let source = """
enum GeneratedFixtureStamp {
    static let value = "build-tool generated"
}
"""

try source.write(
    to: outputURL,
    atomically: true,
    encoding: .utf8
)

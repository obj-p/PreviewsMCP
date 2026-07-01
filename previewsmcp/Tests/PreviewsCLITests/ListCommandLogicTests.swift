import ArgumentParser
import Foundation
@testable import PreviewsCLI
import PreviewsCore
import Testing

/// `list`'s actual #Preview/PreviewProvider parsing is exercised exhaustively
/// against inline source in PreviewsCoreTests/PreviewParserTests.swift — this
/// suite covers `list`'s own logic on top of that: the pre-daemon path
/// validation, directory scanning, and output formatting. `list` never talks
/// to the daemon (it's a `local` CLI subcommand per AGENTS.md), so none of
/// this needs a fake/seam, just direct in-process calls.
@Suite("list command logic")
struct ListCommandLogicTests {
    @Test("rejects a nonexistent path")
    func rejectsNonexistentPath() throws {
        // `ParsableCommand.parse(_:)` wraps a `validate()` throw in
        // ArgumentParser's internal (non-public) CommandError/ParserError, so
        // parse with a valid path first and call `validate()` directly to
        // assert on the public `ValidationError` instead.
        var command = try ListCommand.parse([NSTemporaryDirectory()])
        command.path = "/nonexistent/file.swift"
        do {
            try command.validate()
            Issue.record("expected validate() to throw for a nonexistent path")
        } catch let error as ValidationError {
            #expect(error.message.contains("path does not exist: /nonexistent/file.swift"))
        }
    }

    @Test("swiftFiles finds .swift files recursively, sorted, skipping hidden files")
    func swiftFilesScansRecursively() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-list-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent("Sub"), withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: dir) }

        try "".write(to: dir.appendingPathComponent("B.swift"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent("A.swift"), atomically: true, encoding: .utf8)
        try "".write(
            to: dir.appendingPathComponent("Sub/C.swift"), atomically: true, encoding: .utf8
        )
        try "".write(to: dir.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "".write(to: dir.appendingPathComponent(".hidden.swift"), atomically: true, encoding: .utf8)

        let files = ListCommand.swiftFiles(in: dir.path)

        #expect(files.map { URL(fileURLWithPath: $0).lastPathComponent } == [
            "A.swift", "B.swift", "C.swift",
        ])
    }

    @Test("humanLine formats a named preview")
    func humanLineFormatsNamedPreview() throws {
        let preview = try #require(
            PreviewParser.parse(source: #"#Preview("Loading") { Text("hi") }"#).first
        )

        #expect(ListCommand.humanLine(preview) == "[0] Loading (line 1): Text(\"hi\")")
    }

    @Test("humanLine falls back to 'Preview' when unnamed")
    func humanLineFallsBackWhenUnnamed() throws {
        let preview = try #require(
            PreviewParser.parse(source: #"#Preview { Text("hi") }"#).first
        )

        #expect(ListCommand.humanLine(preview) == "[0] Preview (line 1): Text(\"hi\")")
    }

    @Test("PreviewLine encodes the fields list --json documents")
    func previewLineEncodesExpectedFields() throws {
        let preview = try #require(
            PreviewParser.parse(source: #"#Preview("Loading") { Text("hi") }"#).first
        )
        let line = PreviewLine(from: preview, file: "/tmp/View.swift")

        let object = try #require(
            try JSONSerialization.jsonObject(with: JSONEncoder().encode(line)) as? [String: Any]
        )

        #expect(object["file"] as? String == "/tmp/View.swift")
        #expect(object["index"] as? Int == 0)
        #expect(object["name"] as? String == "Loading")
        #expect(object["line"] as? Int == 1)
        #expect(object["snippet"] as? String == #"Text("hi")"#)
    }
}

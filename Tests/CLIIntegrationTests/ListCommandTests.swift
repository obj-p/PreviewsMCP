import Foundation
import Testing

@Suite("CLI list command")
struct ListCommandTests {

    @Test("Lists #Preview blocks in SPM example ToDoView.swift")
    func listToDoViewPreviews() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run("list", arguments: [file])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[0]"))
        #expect(result.stdout.contains("[1]"))
        #expect(result.stdout.contains("Empty State"))
        #expect(result.stdout.contains("ToDoView"))
    }

    @Test("Lists PreviewProvider previews with display names")
    func listPreviewProviderPreviews() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoProviderPreview.swift").path

        let result = try await CLIRunner.run("list", arguments: [file])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("[0]"))
        #expect(result.stdout.contains("Default"))
        #expect(result.stdout.contains("[1]"))
        #expect(result.stdout.contains("Empty State"))
    }

    @Test("Shows message for file with no previews")
    func listNoPreviewsFile() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/Item.swift").path

        let result = try await CLIRunner.run("list", arguments: [file])

        #expect(result.exitCode == 0)
        #expect(result.stdout.contains("No #Preview blocks found"))
    }

    @Test("Returns non-zero exit code for nonexistent file")
    func listNonexistentFile() async throws {
        let result = try await CLIRunner.run("list", arguments: ["/nonexistent/file.swift"])

        #expect(result.exitCode != 0)
    }

    @Test("--json emits a JSON document with file and previews array")
    func listJSON() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run("list", arguments: [file, "--json"])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        let stdout = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = stdout.data(using: .utf8) else {
            Issue.record("stdout was not UTF-8")
            return
        }
        let parsed = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        #expect(parsed != nil, "stdout should be a JSON object")
        #expect(
            (parsed?["file"] as? String)?.hasSuffix("ToDoView.swift") == true,
            "should contain 'file' field"
        )
        let previews = parsed?["previews"] as? [[String: Any]]
        #expect(previews != nil, "should contain 'previews' array")
        #expect(previews?.count == 2, "ToDoView has 2 previews")
        #expect(previews?.first?["index"] as? Int == 0, "first preview index should be 0")
    }
}

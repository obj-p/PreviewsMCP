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

    @Test("--json emits one self-contained JSON object per preview (NDJSON)")
    func listJSON() async throws {
        let file = CLIRunner.spmExampleRoot
            .appendingPathComponent("Sources/ToDo/ToDoView.swift").path

        let result = try await CLIRunner.run("list", arguments: [file, "--json"])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        let lines = ndjsonLines(result.stdout)
        #expect(lines.count == 2, "ToDoView has 2 previews, one NDJSON line each")

        var indices: [Int] = []
        for line in lines {
            let obj = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "each line must be a standalone JSON object: \(line)"
            )
            #expect((obj["file"] as? String)?.hasSuffix("ToDoView.swift") == true)
            indices.append(try #require(obj["index"] as? Int))
            #expect(obj["line"] is Int)
        }
        #expect(indices.sorted() == [0, 1], "per-file indices start at 0")
    }

    @Test("Scans a directory recursively for previews")
    func listDirectory() async throws {
        let dir = CLIRunner.spmExampleRoot.appendingPathComponent("Sources/ToDo").path

        let result = try await CLIRunner.run("list", arguments: [dir])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        #expect(result.stdout.contains("ToDoView.swift"))
        #expect(result.stdout.contains("UIKitPreview.swift"))
        #expect(result.stdout.contains("Empty State"))
        #expect(result.stderr.contains("previews"), "summary goes to stderr")
    }

    @Test("--json over a directory streams NDJSON aggregated across files")
    func listDirectoryJSON() async throws {
        let dir = CLIRunner.spmExampleRoot.appendingPathComponent("Sources/ToDo").path

        let result = try await CLIRunner.run("list", arguments: [dir, "--json"])

        #expect(result.exitCode == 0, "stderr: \(result.stderr)")
        let lines = ndjsonLines(result.stdout)
        #expect(lines.count >= 5, "the ToDo dir aggregates previews from several files")

        var files: Set<String> = []
        for line in lines {
            let obj = try #require(
                try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                "each line must be a standalone JSON object: \(line)"
            )
            let file = try #require(obj["file"] as? String)
            #expect(file.hasSuffix(".swift"))
            files.insert(file)
        }
        #expect(files.count >= 2, "should aggregate across multiple files")
        #expect(
            !files.contains { $0.hasSuffix("Item.swift") },
            "files with no previews emit no NDJSON lines"
        )
    }
}

private func ndjsonLines(_ stdout: String) -> [String] {
    stdout
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
}

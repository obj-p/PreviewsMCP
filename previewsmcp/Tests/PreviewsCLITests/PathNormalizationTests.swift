import Foundation
@testable import PreviewsCLI
import Testing

@Suite("CLI path normalization at the argument boundary")
struct PathNormalizationTests {
    private static let home = FileManager.default.homeDirectoryForCurrentUser.path

    private static let repoRoot: URL = {
        if let root = ProcessInfo.processInfo.environment["PREVIEWSMCP_REPO_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    private static let existingFile =
        repoRoot
            .appendingPathComponent("examples/spm/Sources/ToDo/ToDoView.swift").path

    @Test("run expands tilde in project and config and resolves the file")
    func runNormalizesPaths() throws {
        let cmd = try RunCommand.parse([
            Self.existingFile, "--project", "~/proj", "--config", "~/c.json",
        ])
        #expect(cmd.file.hasPrefix("/"))
        #expect(cmd.file.hasSuffix("examples/spm/Sources/ToDo/ToDoView.swift"))
        #expect(cmd.project == "\(Self.home)/proj")
        #expect(cmd.config == "\(Self.home)/c.json")
    }

    @Test("snapshot expands tilde in file, project, and config")
    func snapshotNormalizesPaths() throws {
        let cmd = try SnapshotCommand.parse([
            "~/a.swift", "--project", "~/proj", "--config", "~/c.json",
        ])
        #expect(cmd.file == "\(Self.home)/a.swift")
        #expect(cmd.project == "\(Self.home)/proj")
        #expect(cmd.config == "\(Self.home)/c.json")
    }

    @Test("variants expands tilde in file, project, and config")
    func variantsNormalizesPaths() throws {
        let cmd = try VariantsCommand.parse([
            "~/a.swift", "--variant", "dark", "--project", "~/proj", "--config", "~/c.json",
        ])
        #expect(cmd.file == "\(Self.home)/a.swift")
        #expect(cmd.project == "\(Self.home)/proj")
        #expect(cmd.config == "\(Self.home)/c.json")
    }
}

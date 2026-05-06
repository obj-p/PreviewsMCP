import Foundation
import MCP
import Testing

@testable import PreviewsCLI

/// Pin the on-the-wire `ListTools` response so a future refactor can't
/// silently change the schema agents see. The acceptance criterion for
/// the handler-per-file split (architectural plan #1) is that this
/// byte-encoded output is identical pre/post.
///
/// Snapshot lives next to this file as `list_tools_snapshot.json`. To
/// intentionally update it (e.g., when adding a new tool), delete the
/// file and re-run — the test will write the new snapshot and report
/// "blessed" so the change is visible in the diff.
@Suite("ListTools schema snapshot")
struct ListToolsSnapshotTests {

    @Test("schema bytes are stable")
    func schemaBytesAreStable() throws {
        let snapshotPath = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("list_tools_snapshot.json")

        // Encode through the SDK's CallTool.Result-shaped Tool type using
        // sorted keys so the byte output is deterministic regardless of
        // the unordered `[String: Value]` Dictionary backing of object
        // schemas. Pretty-printed for human-readable diffs in PRs.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        let actual = try encoder.encode(mcpToolSchemas())

        let fm = FileManager.default
        if !fm.fileExists(atPath: snapshotPath.path) {
            // Bless mode: write the snapshot and fail the test so CI
            // catches an unblessed run. We deliberately skip the
            // equality check below — the snapshot was just written so
            // it would tautologically pass; the issue-record is the
            // signal to commit the new fixture and re-run.
            try actual.write(to: snapshotPath)
            Issue.record(
                "Blessed initial snapshot at \(snapshotPath.path) — re-run to verify"
            )
            return
        }

        let expected = try Data(contentsOf: snapshotPath)
        if actual != expected {
            // Drop the actual bytes next to the expected so a diff tool
            // shows what changed without rerunning.
            let actualPath = snapshotPath.deletingPathExtension()
                .appendingPathExtension("actual.json")
            try? actual.write(to: actualPath)
            Issue.record(
                "ListTools schema drifted. expected=\(snapshotPath.path) actual=\(actualPath.path). If intentional, delete the .json snapshot and re-run."
            )
        }
        #expect(actual == expected)
    }
}

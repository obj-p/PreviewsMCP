import Foundation
import Testing

@testable import PreviewsCore

/// Pin the on-disk format of `Log` so future changes don't silently
/// break `previewsmcp logs` consumers or grep patterns in CI dumps.
///
/// Serialized because `captureStderr` rebinds the process-global fd 2
/// for the duration of `body` — running these in parallel would race
/// on whose `dup2` was most recent.
@Suite("Log", .serialized)
struct LogTests {

    @Test("info writes timestamped plain message to stderr")
    func infoFormat() {
        let line = captureStderr { Log.info("hello world") }
        let pattern = #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\] hello world\n$"#
        #expect(
            line.range(of: pattern, options: .regularExpression) != nil,
            "got: \(line.debugDescription)")
    }

    @Test("warn prefixes WARN: after the timestamp")
    func warnFormat() {
        let line = captureStderr { Log.warn("retrying") }
        let pattern = #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\] WARN: retrying\n$"#
        #expect(
            line.range(of: pattern, options: .regularExpression) != nil,
            "got: \(line.debugDescription)")
    }

    @Test("error prefixes ERROR: after the timestamp")
    func errorFormat() {
        let line = captureStderr { Log.error("boom") }
        let pattern = #"^\[\d{2}:\d{2}:\d{2}\.\d{3}\] ERROR: boom\n$"#
        #expect(
            line.range(of: pattern, options: .regularExpression) != nil,
            "got: \(line.debugDescription)")
    }

    /// Redirects fd 2 to a temp file for the duration of `body`, then
    /// returns whatever was written. Uses `dup2` so we capture writes
    /// from inside `Log` itself (which holds `FileHandle.standardError`,
    /// a wrapper around fd 2 — replacing the underlying fd is what
    /// reroutes its output).
    private func captureStderr(_ body: () -> Void) -> String {
        let savedStderr = dup(fileno(stderr))
        defer { close(savedStderr) }
        let temp = FileManager.default.temporaryDirectory
            .appendingPathComponent("log-test-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: temp.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let writer = FileHandle(forWritingAtPath: temp.path) else { return "" }
        defer { try? writer.close() }

        dup2(writer.fileDescriptor, fileno(stderr))
        body()
        fflush(stderr)
        dup2(savedStderr, fileno(stderr))

        return (try? String(contentsOf: temp, encoding: .utf8)) ?? ""
    }
}

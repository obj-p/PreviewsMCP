import Foundation
import Testing

/// Integration tests for the `logs` subcommand — the debugging ergonomic
/// wrapper over `tail` on `~/.previewsmcp/serve.log`.
///
/// Shares daemon directory state (`serve.log` lives under `$PREVIEWSMCP_SOCKET_DIR`
/// or `~/.previewsmcp/`) with every other daemon-touching suite. Guard with
/// `DaemonTestLock` so parallel `Run`/`Kill` suites don't rewrite the log
/// under us.
@Suite(.serialized)
struct LogsCommandTests {

    @Test(
        "logs -n prints the last N lines of an existing log",
        .timeLimit(.minutes(1))
    )
    func snapshotReturnsTailOfExistingLog() async throws {
        try await DaemonTestLock.run {
            // DaemonTestLock already ensured the directory exists and wrote
            // a `=== TEST: ... ===` marker into serve.log. Append a known
            // sentinel block that we can locate deterministically with -n.
            let logURL = CLIRunner.daemonLogFile
            let sentinel = (1...5).map { "logs-test-line-\($0)" }
            if let handle = try? FileHandle(forWritingTo: logURL) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data((sentinel.joined(separator: "\n") + "\n").utf8))
                try? handle.close()
            }

            let result = try await CLIRunner.run("logs", arguments: ["-n", "5"])
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")

            let lines = result.stdout.split(separator: "\n").map(String.init)
            #expect(lines == sentinel, "expected exact sentinel tail, got: \(result.stdout)")
        }
    }

    @Test(
        "logs creates the log file when missing and exits 0",
        .timeLimit(.minutes(1))
    )
    func snapshotCreatesLogFileWhenMissing() async throws {
        try await DaemonTestLock.run {
            let logURL = CLIRunner.daemonLogFile
            try? FileManager.default.removeItem(at: logURL)
            #expect(
                !FileManager.default.fileExists(atPath: logURL.path),
                "precondition: log file should be absent")

            let result = try await CLIRunner.run("logs")
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stdout.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                "stdout should be empty when log was created fresh, got: '\(result.stdout)'")
            #expect(
                FileManager.default.fileExists(atPath: logURL.path),
                "logs should have created the missing log file")
        }
    }

    /// Follow mode is the command's only non-trivial runtime path — tail
    /// streams, then SIGINT must propagate to the child so the CLI doesn't
    /// leave orphaned tail processes. `CLIRunner.run` can't exercise this
    /// (it captures stdout end-to-end), so drive a raw Process the way
    /// RunCommandTests does for its SIGINT test.
    ///
    /// Uses `-n 0` so the initial-content print doesn't race with our
    /// sentinel append; we poke the log on every poll iteration until the
    /// stream observes the sentinel, avoiding a magic "wait for tail to
    /// arm its watcher" sleep.
    @Test(
        "logs --follow streams new lines and exits on SIGINT",
        .timeLimit(.minutes(1))
    )
    func followStreamsAndExitsOnSIGINT() async throws {
        try await DaemonTestLock.run {
            let logURL = CLIRunner.daemonLogFile
            // Reset to a known state so our sentinel is uniquely identifiable.
            try? Data().write(to: logURL)

            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
            proc.arguments = ["logs", "--follow", "-n", "0"]
            // Inherit PREVIEWSMCP_SOCKET_DIR so the child targets the same
            // isolated log as the test.
            proc.environment = ProcessInfo.processInfo.environment
            let stdoutPipe = Pipe()
            proc.standardOutput = stdoutPipe
            proc.standardError = FileHandle.nullDevice
            try proc.run()

            let sentinel = "logs-follow-sentinel-\(UUID().uuidString)"
            let sawSentinel = try await Self.waitForStdoutMatch(
                pipe: stdoutPipe, substring: sentinel, timeout: 10
            ) {
                // Rewrite the sentinel on every poll. One of these writes
                // will land after tail has opened the file and armed its
                // watcher, at which point the stream picks it up.
                if let handle = try? FileHandle(forWritingTo: logURL) {
                    _ = try? handle.seekToEnd()
                    try? handle.write(contentsOf: Data((sentinel + "\n").utf8))
                    try? handle.close()
                }
            }
            #expect(sawSentinel, "sentinel '\(sentinel)' should stream to stdout within 10s")
            #expect(proc.isRunning, "follow mode should not exit on its own")

            kill(proc.processIdentifier, SIGINT)
            let deadline = Date().addingTimeInterval(5)
            while proc.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if proc.isRunning { proc.terminate() }
            #expect(!proc.isRunning, "logs --follow should exit within 5s of SIGINT")
        }
    }

    // MARK: - Helpers

    /// Polls `pipe` for `substring` until the deadline. `poke` runs on each
    /// iteration before the sleep — use it to re-trigger the event the
    /// stream is supposed to observe, so the test doesn't depend on
    /// subprocess-startup timing.
    private static func waitForStdoutMatch(
        pipe: Pipe,
        substring: String,
        timeout: TimeInterval,
        poke: () async throws -> Void = {}
    ) async throws -> Bool {
        let buffer = PipeBuffer()
        let handle = pipe.fileHandleForReading
        handle.readabilityHandler = { fh in
            let data = fh.availableData
            if !data.isEmpty, let text = String(data: data, encoding: .utf8) {
                buffer.append(text)
            }
        }
        defer { handle.readabilityHandler = nil }

        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if buffer.contents().contains(substring) { return true }
            try await poke()
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        return false
    }
}

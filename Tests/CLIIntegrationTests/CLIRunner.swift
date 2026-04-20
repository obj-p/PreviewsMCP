import Foundation
import Testing
import os

/// Result of running the CLI binary.
struct CLIResult: Sendable {
    let stdout: String
    let stderr: String
    let exitCode: Int32
}

/// Helper for running the `previewsmcp` CLI binary as a subprocess.
enum CLIRunner {

    // MARK: - Paths

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // CLIIntegrationTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root

    static let binaryPath: String =
        repoRoot
        .appendingPathComponent(".build/debug/previewsmcp").path

    static let spmExampleRoot: URL = repoRoot.appendingPathComponent("examples/spm")
    static let xcodeprojExampleRoot: URL = repoRoot.appendingPathComponent("examples/xcodeproj")
    static let xcworkspaceExampleRoot: URL = repoRoot.appendingPathComponent("examples/xcworkspace")
    static let bazelExampleRoot: URL = repoRoot.appendingPathComponent("examples/bazel")

    /// Mirrors `Sources/PreviewsCLI/DaemonPaths.swift`. The daemon writes its
    /// stderr to this file when launched detached. We can't import PreviewsCLI
    /// from this test target, so the resolution logic is duplicated here.
    static var daemonLogFile: URL {
        let dir: URL
        if let override = ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"] {
            dir = URL(fileURLWithPath: override, isDirectory: true)
        } else {
            dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent(".previewsmcp", isDirectory: true)
        }
        return dir.appendingPathComponent("serve.log")
    }

    // MARK: - Process runner

    /// Per-subcommand timeout for `previewsmcp <subcommand>` invocations. Used
    /// when the caller doesn't pass an explicit `timeout`. Tuned so that a
    /// hung subprocess fails the individual call rather than the whole test
    /// suite — see issue #127.
    private static func defaultTimeout(for subcommand: String) -> Duration {
        switch subcommand {
        case "start", "run", "snapshot", "variants":
            // Commands that can trigger compile + (iOS) simulator boot +
            // host-app build + render in a single invocation. Last-known-
            // green iosCLIWorkflow took 274s total for run + touch×2 +
            // elements×2 + variants + stop — meaning the `run` step alone
            // consumed ~200-230s on that particular CI runner. 360s gives
            // ~50% headroom over the observed time. Cold Bazel/SPM
            // first-build can exceed 60s even on macOS, also covered.
            .seconds(360)
        case "kill-daemon":
            .seconds(10)
        default:
            .seconds(60)
        }
    }

    /// Run `previewsmcp` with the given subcommand and arguments.
    ///
    /// Hangs are bounded by `timeout` (default = `defaultTimeout(for:)`).
    /// On timeout the subprocess is SIGTERM'd then SIGKILL'd after a 2s
    /// grace; the captured stderr and the daemon's `serve.log` are dumped
    /// via `Issue.record` and the call throws `CLIRunnerError.timedOut`.
    /// The runner is cancellation-safe: if the parent task is cancelled
    /// (e.g., by `.timeLimit` firing), the subprocess is killed too so
    /// the daemon doesn't stay busy serving an abandoned client.
    static func run(
        _ subcommand: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        timeout: Duration? = nil
    ) async throws -> CLIResult {
        try #require(
            FileManager.default.fileExists(atPath: binaryPath),
            "previewsmcp binary not found at \(binaryPath). Run 'swift build' first."
        )
        let effective = timeout ?? defaultTimeout(for: subcommand)
        return try await runProcess(
            binaryPath,
            arguments: [subcommand] + arguments,
            workingDirectory: workingDirectory,
            label: subcommand,
            timeout: effective
        )
    }

    /// Check if a command-line tool is available on PATH.
    static func toolAvailable(_ name: String) async -> Bool {
        let result = try? await runProcess(
            "/usr/bin/which",
            arguments: [name],
            workingDirectory: nil,
            label: "which",
            timeout: .seconds(10)
        )
        return result?.exitCode == 0
    }

    // MARK: - Image validation

    static func assertValidPNG(
        at path: String,
        minSize: Int = 1024,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count >= minSize, "PNG should be at least \(minSize) bytes, got \(data.count)")
        #expect(data.count >= 2 && data[0] == 0x89 && data[1] == 0x50, "File should have PNG header")
        if let expectedWidth, let expectedHeight {
            let (w, h) = pngDimensions(data)
            #expect(w == expectedWidth, "PNG width should be \(expectedWidth), got \(w)")
            #expect(h == expectedHeight, "PNG height should be \(expectedHeight), got \(h)")
        }
    }

    static func assertValidJPEG(at path: String, minSize: Int = 1024) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        #expect(data.count >= minSize, "JPEG should be at least \(minSize) bytes, got \(data.count)")
        #expect(data.count >= 2 && data[0] == 0xFF && data[1] == 0xD8, "File should have JPEG header")
    }

    /// Read width and height from PNG IHDR chunk (bytes 16-23, big-endian uint32).
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard data.count >= 24 else { return (0, 0) }
        let w = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
        let h = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        return (w, h)
    }

    // MARK: - Temp directory

    static func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-integration-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Run an arbitrary external process (not the CLI binary). External
    /// tools (xcodegen, simctl, etc.) get a generous 5-minute default
    /// timeout; override per-call if needed.
    static func runExternal(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil,
        timeout: Duration = .seconds(300)
    ) async throws -> CLIResult {
        try await runProcess(
            executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            label: "external:\((executable as NSString).lastPathComponent)",
            timeout: timeout
        )
    }

    // MARK: - Private process helper

    /// Cancellation- and timeout-safe subprocess runner.
    ///
    /// State machine guards the continuation against double-resume and
    /// guarantees the subprocess is signalled exactly once on the
    /// terminal path (normal exit, timeout, cancellation, or
    /// `process.run()` throw). See issue #127 for context — the prior
    /// implementation used `withCheckedThrowingContinuation` with no
    /// cancellation handler, which left subprocesses running after
    /// `.timeLimit` fired and wedged subsequent tests.
    private static func runProcess(
        _ executable: String,
        arguments: [String],
        workingDirectory: URL?,
        label: String,
        timeout: Duration
    ) async throws -> CLIResult {
        // Per-call stderr capture file. Mirrors MCPTestServer's pattern
        // (PR #126): a plain file handle avoids both the CFRunLoop
        // retention bug of Pipe+readabilityHandler and the
        // shared-stderr NSApplication-startup hang of inheriting
        // FileHandle.standardError.
        let stderrLogPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("cli-runner-stderr-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrLogPath.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: stderrLogPath) }
        guard let stderrHandle = FileHandle(forWritingAtPath: stderrLogPath.path) else {
            throw CLIRunnerError.cannotCreateStderrLog(stderrLogPath.path)
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }
        process.standardError = stderrHandle

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        // Read stdout on a background thread to avoid pipe-full deadlocks.
        let stdoutBox = LockedData()
        let stdoutGroup = DispatchGroup()
        stdoutGroup.enter()
        DispatchQueue.global().async {
            stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stdoutGroup.leave()
        }

        let state = OSAllocatedUnfairLock<RunState>(initialState: .notStarted)
        let stderrPath = stderrLogPath
        let runLabel = label
        let runTimeout = timeout

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<CLIResult, Error>) in

                // Schedule the timeout. Cancelled when the process exits
                // normally or when run() throws so it can't fire late.
                let timeoutTask = Task<Void, Never> {
                    try? await Task.sleep(for: runTimeout)
                    if Task.isCancelled { return }

                    let pid = state.withLock { s -> pid_t? in
                        switch s {
                        case .running(let p):
                            s = .resumed
                            return p
                        case .notStarted, .resumed:
                            return nil
                        }
                    }
                    guard let pid else { return }

                    Foundation.kill(pid, SIGTERM)
                    DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                        Foundation.kill(pid, SIGKILL)
                    }

                    let stderrText = Self.readFile(stderrPath)
                    let serveLogText = Self.readFile(daemonLogFile)
                    Issue.record(
                        """
                        CLI subprocess timed out after \(runTimeout) (label: \(runLabel)).

                        --- subprocess stderr ---
                        \(stderrText.isEmpty ? "(empty)" : stderrText)

                        --- daemon serve.log (\(daemonLogFile.path)) ---
                        \(serveLogText.isEmpty ? "(empty or missing)" : serveLogText)
                        """
                    )
                    continuation.resume(
                        throwing: CLIRunnerError.timedOut(
                            label: runLabel, duration: runTimeout))
                }

                process.terminationHandler = { proc in
                    let shouldResume = state.withLock { s -> Bool in
                        switch s {
                        case .running:
                            s = .resumed
                            return true
                        case .notStarted, .resumed:
                            return false
                        }
                    }
                    guard shouldResume else { return }

                    timeoutTask.cancel()
                    stdoutGroup.wait()
                    let stdout = (String(data: stdoutBox.value, encoding: .utf8) ?? "")
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let stderr = Self.readFile(stderrPath)
                    continuation.resume(
                        returning: CLIResult(
                            stdout: stdout, stderr: stderr,
                            exitCode: proc.terminationStatus))
                }

                do {
                    try process.run()
                    let pid = process.processIdentifier
                    let raced = state.withLock { s -> Bool in
                        switch s {
                        case .notStarted:
                            s = .running(pid)
                            return false
                        case .running, .resumed:
                            // Cancellation handler ran between Process()
                            // init and run() and tagged us as resumed —
                            // kill the process we just started.
                            return true
                        }
                    }
                    if raced {
                        Foundation.kill(pid, SIGTERM)
                        DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                            Foundation.kill(pid, SIGKILL)
                        }
                        timeoutTask.cancel()
                        continuation.resume(throwing: CancellationError())
                    }
                } catch {
                    let shouldResume = state.withLock { s -> Bool in
                        switch s {
                        case .notStarted:
                            s = .resumed
                            return true
                        case .running, .resumed:
                            return false
                        }
                    }
                    if shouldResume {
                        timeoutTask.cancel()
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            // Synchronous handler. Signal the subprocess if it's running;
            // do NOT resume the continuation here — terminationHandler
            // will fire after SIGKILL and resume with the killed exit
            // status. The caller's next `try await` then surfaces the
            // CancellationError on its own.
            let pid = state.withLock { s -> pid_t? in
                switch s {
                case .running(let p):
                    return p
                case .notStarted:
                    // Race: cancellation before run() completed. Mark
                    // resumed so the run() path knows to resume with
                    // CancellationError and kill whatever pid it just
                    // started.
                    s = .resumed
                    return nil
                case .resumed:
                    return nil
                }
            }
            guard let pid else { return }
            Foundation.kill(pid, SIGTERM)
            DispatchQueue.global().asyncAfter(deadline: .now() + 2) {
                Foundation.kill(pid, SIGKILL)
            }
        }
    }

    private static func readFile(_ url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }
}

/// Subprocess lifecycle states for `runProcess`. The state machine ensures
/// the continuation is resumed exactly once across the four terminal paths
/// (normal exit, timeout, cancellation, run() throw).
private enum RunState: Sendable {
    case notStarted
    case running(pid_t)
    case resumed
}

enum CLIRunnerError: Error, LocalizedError {
    case timedOut(label: String, duration: Duration)
    case cannotCreateStderrLog(String)

    var errorDescription: String? {
        switch self {
        case .timedOut(let label, let duration):
            "CLI invocation '\(label)' timed out after \(duration)"
        case .cannotCreateStderrLog(let path):
            "Could not open stderr log for writing at \(path)"
        }
    }
}

/// Thread-safe mutable data buffer for collecting pipe output.
private final class LockedData: @unchecked Sendable {
    private let lock = NSLock()
    private var _value = Data()

    var value: Data {
        lock.lock()
        defer { lock.unlock() }
        return _value
    }

    func append(_ data: Data) {
        guard !data.isEmpty else { return }
        lock.lock()
        _value.append(data)
        lock.unlock()
    }
}

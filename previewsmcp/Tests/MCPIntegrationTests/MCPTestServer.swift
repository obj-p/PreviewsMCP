import AppKit
import Foundation
import MCP
import os
import System
import Testing

/// Manages a `previewsmcp serve` subprocess with an MCP Client connected via stdio pipes.
/// Thread safety: instances are only used within serialized test suites — never shared across
/// isolation boundaries.
final class MCPTestServer: @unchecked Sendable {
    // MARK: - Paths

    static let repoRoot: URL = {
        if let root = ProcessInfo.processInfo.environment["PREVIEWSMCP_REPO_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // MCPIntegrationTests/
            .deletingLastPathComponent() // Tests/
            .deletingLastPathComponent() // repo root
    }()

    static let binaryPath: String = {
        let env = ProcessInfo.processInfo.environment
        if let explicit = env["PREVIEWSMCP_BINARY"] {
            if explicit.hasPrefix("/") { return explicit }
            if let srcdir = env["TEST_SRCDIR"] {
                return URL(fileURLWithPath: srcdir)
                    .appendingPathComponent(explicit).path
            }
            return explicit
        }
        return repoRoot.appendingPathComponent(".build/debug/previewsmcp").path
    }()

    static let spmExampleRoot: URL = repoRoot.appendingPathComponent("examples/spm")
    static let toDoViewPath: String =
        spmExampleRoot.appendingPathComponent("Sources/ToDo/ToDoView.swift").path
    static let toDoProviderPath: String =
        spmExampleRoot.appendingPathComponent("Sources/ToDo/ToDoProviderPreview.swift").path

    // MARK: - State

    private let process: Process
    private let client: Client
    private let stdinPipe: Pipe
    private let stdoutPipe: Pipe
    /// Path to the per-instance log file that captures the server subprocess's stderr.
    /// Persists on disk after `stop()` so post-mortem inspection is possible.
    let stderrLogPath: URL
    private let startedAt: ContinuousClock.Instant
    /// Flag the watchdog thread polls between sleeps. Mutated from `stop()`
    /// via the lock; the thread reads it once per iteration.
    private let watchdogShouldStop = OSAllocatedUnfairLock<Bool>(initialState: false)

    /// Compat-shim probe: subscribe exactly like a pre-stage-6 CLI
    /// (register a log handler, then send logging/setLevel(.debug)) and
    /// invoke `onHeartbeat` for every heartbeat notification the daemon
    /// sends back. See the shim in `configureMCPServer`.
    func requestDebugLogging(onHeartbeat: @escaping @Sendable () -> Void) async throws {
        await client.onNotification(LogMessageNotification.self) { message in
            if message.params.logger == "heartbeat" { onHeartbeat() }
        }
        try await client.setLoggingLevel(.debug)
    }

    private init(
        process: Process, client: Client,
        stdinPipe: Pipe, stdoutPipe: Pipe,
        stderrLogPath: URL,
        startedAt: ContinuousClock.Instant
    ) {
        self.process = process
        self.client = client
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrLogPath = stderrLogPath
        self.startedAt = startedAt
    }

    // MARK: - Lifecycle

    /// Spawn `previewsmcp serve` and connect an MCP client.
    static func start() async throws -> MCPTestServer {
        try #require(
            FileManager.default.fileExists(atPath: binaryPath),
            "previewsmcp binary not found at \(binaryPath). Run 'swift build' first."
        )

        let process = Process()
        process.executableURL = URL(fileURLWithPath: binaryPath)
        process.arguments = ["serve"]
        // Export the per-run socket dir so the spawned daemon's production
        // DaemonPaths resolves to it (#283). DaemonTestLock derives this from
        // $TEST_TMPDIR when no explicit PREVIEWSMCP_SOCKET_DIR is set, giving
        // each Bazel test target an isolated, auto-cleaned daemon socket.
        var childEnv = ProcessInfo.processInfo.environment
        childEnv["PREVIEWSMCP_SOCKET_DIR"] = DaemonTestLock.effectiveSocketDir
        process.environment = childEnv

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        // Capture server stderr to a per-instance file. Two earlier approaches caused
        // CI hangs on macOS 15:
        //  1. Pipe + readabilityHandler — the dispatch source persisted in the test
        //     binary's CFRunLoop after the subprocess died, blocking process exit.
        //  2. Sharing FileHandle.standardError with the child — caused previewsmcp's
        //     own startup to hang on subsequent test runs (cause unclear; possibly
        //     related to NSApplication's stderr handling).
        // Writing to a plain file handle avoids both: no dispatch source (so nothing
        // to persist in the parent's CFRunLoop) and an isolated fd (so the child
        // doesn't inherit the parent's stderr). This restores the diagnostics that
        // were previously lost to /dev/null.
        let stderrLogPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-test-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: stderrLogPath.path, contents: nil)
        guard let stderrHandle = FileHandle(forWritingAtPath: stderrLogPath.path) else {
            throw MCPTestError.cannotCreateStderrLog(stderrLogPath.path)
        }
        process.standardError = stderrHandle

        try process.run()

        let readFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let writeFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: readFD, output: writeFD)

        let client = Client(name: "mcp-integration-test", version: "1.0")
        _ = try await client.connect(transport: transport)

        let startedAt = ContinuousClock.now

        let server = MCPTestServer(
            process: process, client: client,
            stdinPipe: stdinPipe, stdoutPipe: stdoutPipe,
            stderrLogPath: stderrLogPath,
            startedAt: startedAt
        )

        // Watchdog: a detached kernel thread (not GCD, not Swift
        // concurrency) emits a heartbeat every 60s so hangs caused by
        // 100%-CPU busy-spins still produce diagnostic output. An
        // earlier attempt with `DispatchSource.makeTimerSource(qos:
        // .utility)` produced no heartbeats in a real CI hang (PR #134
        // run 72345678664): libdispatch's utility-QoS worker threads
        // were starved by whatever was burning the cores. Detaching a
        // raw pthread via `Thread.detachNewThread` sidesteps QoS
        // scheduling and Swift concurrency entirely, and `Thread.sleep`
        // blocks in the kernel rather than suspending a cooperative
        // task.
        Thread.detachNewThread { [weak server] in
            Thread.current.name = "MCPTestServer.watchdog"
            while true {
                Thread.sleep(forTimeInterval: 60)
                guard let server else { return }
                if server.watchdogShouldStop.withLock({ $0 }) { return }
                server.emitWatchdogHeartbeat()
            }
        }

        // Detect unexpected server termination so pending callTool requests fail fast
        // instead of hanging forever on the MCP client's continuation, and so the SDK's
        // busy-spin loop (see stop() docs) doesn't accumulate.
        process.terminationHandler = { [weak server] _ in
            Task {
                await server?.client.disconnect()
            }
        }

        return server
    }

    deinit {
        stop()
    }

    /// Terminate subprocess and disconnect MCP client. Safe to call multiple times.
    ///
    /// Disconnecting the client cancels its internal message-handling Task. Without
    /// this, the SDK's loop hits a busy-spin once the transport is dead: the
    /// for-await loop on the finished message stream returns immediately, then the
    /// outer `repeat ... while true` loop iterates again with no `await` point that
    /// suspends, consuming 100% CPU. With multiple tests in a serialized suite,
    /// accumulated orphan tasks would starve the test runner and hang CI.
    ///
    /// Synchronous wrapper (using a semaphore) so it can be used from `defer`.
    /// Safe from deadlock because Client.disconnect() runs on the client actor's
    /// executor, which is independent of any thread held by the calling defer.
    func stop() {
        // Diagnostics for issue #156: write a phase trace to the per-instance
        // stderr log file and to the test-process stderr. The hung-test
        // post-mortem so far shows the daemon completing preview_stop in 3 ms
        // and the test then wedging for 1200 s — most likely inside
        // waitUntilExit() or the SDK disconnect. These lines bracket each
        // phase so the next failed dump pinpoints which one.
        let traceFD = open(stderrLogPath.path, O_WRONLY | O_APPEND)
        func trace(_ message: String) {
            let stamp = Date().formatted(.iso8601.time(includingFractionalSeconds: true))
            let line = "[stop \(stamp)] \(message)\n"
            fputs(line, stderr)
            fflush(stderr)
            if traceFD >= 0 {
                _ = line.withCString { Darwin.write(traceFD, $0, strlen($0)) }
            }
        }

        // Signal the watchdog thread to exit on its next poll. It may
        // sleep up to 60s past stop() before noticing — that's fine,
        // the thread is lightweight and holds nothing but a weak
        // reference to self.
        trace("enter")
        watchdogShouldStop.withLock { $0 = true }
        process.terminationHandler = nil
        if process.isRunning {
            trace("process.terminate")
            process.terminate()
            // Bounded wait: poll instead of `process.waitUntilExit()`, which
            // blocks indefinitely. CI evidence (issue #156) shows the daemon
            // sometimes ignores SIGTERM, wedging the test for 1200 s. After
            // 5 s, escalate to SIGKILL so cleanup can finish in seconds.
            let deadline = ContinuousClock.now + .seconds(5)
            while process.isRunning, ContinuousClock.now < deadline {
                Thread.sleep(forTimeInterval: 0.05)
            }
            if process.isRunning {
                trace("SIGTERM ignored after 5s — escalating to SIGKILL pid=\(process.processIdentifier)")
                kill(process.processIdentifier, SIGKILL)
                process.waitUntilExit()
                trace("process.waitUntilExit (returned after SIGKILL)")
            } else {
                trace("process exited after SIGTERM")
            }
        } else {
            trace("process not running")
        }
        let semaphore = DispatchSemaphore(value: 0)
        let client = client
        trace("client.disconnect (dispatched)")
        Task.detached {
            await client.disconnect()
            semaphore.signal()
        }
        semaphore.wait()
        trace("client.disconnect (returned)")
        if traceFD >= 0 { close(traceFD) }
    }

    // MARK: - Tool calls

    /// Call an MCP tool and return the result.
    ///
    /// Bounded by a default 60-second timeout so a never-arriving response from
    /// the daemon (e.g., an MCP SDK transport drop, see issue #156) fails the
    /// test in seconds instead of wedging until the per-test 1200 s `.timeLimit`
    /// fires. Callers that need a different bound should use
    /// `callToolWithTimeout(name:arguments:timeout:)` directly.
    func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try await callToolWithTimeout(
            name: name, arguments: arguments, timeout: .seconds(60)
        )
    }

    /// Call an MCP tool bounded by `timeout`. On timeout, dumps the captured
    /// server stderr via `Issue.record` so the hang has diagnostic context,
    /// then rethrows `MCPTestError.timedOut`.
    func callToolWithTimeout(
        name: String,
        arguments: [String: Value]? = nil,
        timeout: Duration = .seconds(30)
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        do {
            return try await Self.withTimeout(timeout, process: process) { [self] in
                try await client.callTool(name: name, arguments: arguments)
            }
        } catch is TestTimeoutSentinel {
            Issue.record("callTool(\(name)) timed out after \(timeout). Server stderr:\n\(stderrLog())")
            throw MCPTestError.timedOut(operation: "callTool(\(name))", duration: timeout)
        }
    }

    /// Call an MCP tool and return the full `CallTool.Result` including
    /// the `structuredContent` field that the tuple-returning `callTool`
    /// overload drops. Needed for tests that assert structured payload
    /// shape.
    func callToolResult(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        let context: RequestContext<CallTool.Result> = try await client.callTool(
            name: name, arguments: arguments
        )
        return try await context.value
    }

    /// Decode `result.structuredContent` into a Codable DTO.
    static func decodeStructured<T: Decodable>(
        _: T.Type,
        from result: CallTool.Result,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> T {
        guard let structured = result.structuredContent else {
            Issue.record(
                "Expected structuredContent on tool result, got nil",
                sourceLocation: SourceLocation(fileID: "\(file)", filePath: "\(file)", line: Int(line), column: 1)
            )
            throw MCPTestError.noStructuredContent
        }
        let data = try JSONEncoder().encode(structured)
        return try JSONDecoder().decode(T.self, from: data)
    }

    // MARK: - Response helpers

    /// Extract all text content from a tool result, joined by newlines.
    static func extractText(from content: [Tool.Content]) -> String {
        content.compactMap { item in
            if case let .text(text) = item { return text }
            return nil
        }.joined(separator: "\n")
    }

    /// Extract the session ID (UUID) from a tool result containing "Session ID: <uuid>".
    static func extractSessionID(from content: [Tool.Content]) throws -> String {
        let text = extractText(from: content)
        let pattern = /Session ID: ([0-9a-fA-F-]{36})/
        guard let match = text.firstMatch(of: pattern) else {
            Issue.record("No session ID found in response: \(text)")
            throw MCPTestError.noSessionID(text)
        }
        return String(match.1)
    }

    /// Extract image data from a tool result containing an image content item.
    static func extractImageData(from content: [Tool.Content]) throws -> (data: Data, mimeType: String) {
        for item in content {
            if case let .image(base64, mimeType, _) = item {
                guard let data = Data(base64Encoded: base64) else {
                    throw MCPTestError.invalidBase64
                }
                return (data, mimeType)
            }
        }
        throw MCPTestError.noImageContent
    }

    /// Assert that image content is a valid JPEG or PNG with minimum size and optional dimension check.
    static func assertValidImage(
        _ content: [Tool.Content],
        expectedMimeType: String? = nil,
        minSize: Int = 1024,
        expectedWidth: Int? = nil,
        expectedHeight: Int? = nil
    ) throws {
        let (data, mimeType) = try extractImageData(from: content)
        if let expected = expectedMimeType {
            #expect(mimeType == expected, "Expected \(expected), got \(mimeType)")
        }
        #expect(data.count >= minSize, "Image should be >= \(minSize) bytes, got \(data.count)")
        if mimeType == "image/png" {
            #expect(data[0] == 0x89 && data[1] == 0x50, "Expected PNG header")
            if let expectedWidth, let expectedHeight {
                let (w, h) = pngDimensions(data)
                #expect(w == expectedWidth, "PNG width should be \(expectedWidth), got \(w)")
                #expect(h == expectedHeight, "PNG height should be \(expectedHeight), got \(h)")
            }
        } else if mimeType == "image/jpeg" {
            #expect(data[0] == 0xFF && data[1] == 0xD8, "Expected JPEG header")
        }
    }

    static func assertNotBlank(_ content: [Tool.Content]) throws {
        let (data, _) = try extractImageData(from: content)
        guard let rep = NSBitmapImageRep(data: data) else {
            Issue.record("Snapshot did not decode as an image")
            return
        }
        let stepX = max(1, rep.pixelsWide / 20)
        let stepY = max(1, rep.pixelsHigh / 20)
        var reference: NSColor?
        for y in stride(from: 0, to: rep.pixelsHigh, by: stepY) {
            for x in stride(from: 0, to: rep.pixelsWide, by: stepX) {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else { continue }
                guard let ref = reference else { reference = c; continue }
                if abs(c.redComponent - ref.redComponent) > 0.05
                    || abs(c.greenComponent - ref.greenComponent) > 0.05
                    || abs(c.blueComponent - ref.blueComponent) > 0.05
                {
                    return
                }
            }
        }
        Issue.record("Snapshot appears blank (uniform color) — nothing rendered")
    }

    /// Extract all image content items from a tool result.
    static func extractImages(from content: [Tool.Content]) -> [(data: Data, mimeType: String)] {
        content.compactMap { item in
            if case let .image(base64, mimeType, _) = item,
               let data = Data(base64Encoded: base64)
            {
                return (data, mimeType)
            }
            return nil
        }
    }

    /// Read width and height from PNG IHDR chunk (bytes 16-23, big-endian uint32).
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard data.count >= 24 else { return (0, 0) }
        let w = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
        let h = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        return (w, h)
    }

    // MARK: - Stderr capture

    /// Return the current contents of the server's captured stderr log.
    /// Safe to call at any time; reads may trail in-flight writes slightly.
    func stderrLog() -> String {
        (try? String(contentsOfFile: stderrLogPath.path, encoding: .utf8)) ?? ""
    }

    /// Periodic diagnostic emitted by the watchdog timer. Writes the server
    /// subprocess's elapsed runtime and the tail of its captured stderr to
    /// the test process's own stderr via a blocking fputs, bypassing both
    /// Issue.record (which requires Swift concurrency to be making forward
    /// progress) and Swift's stdout caching.
    ///
    /// Silent on the happy path — tests that complete in under 60s never
    /// trigger a heartbeat. A test that hangs produces one line per minute
    /// with the server's most recent stderr lines, so the next CI failure
    /// has enough context to localize the hang.
    private func emitWatchdogHeartbeat() {
        let elapsed = ContinuousClock.now - startedAt
        let elapsedSeconds = Int(elapsed.components.seconds)
        let log = stderrLog()
        // Filter out our own prior heartbeat lines so each tick reports the
        // daemon's recent activity, not a recursive nest of previous tails.
        let tailLines =
            log
                .split(separator: "\n", omittingEmptySubsequences: false)
                .filter { line in
                    !line.contains("[MCPTestServer watchdog")
                        && !line.hasPrefix("[/watchdog]")
                }
                .suffix(5)
                .joined(separator: "\n")
        let tailDescription = tailLines.isEmpty ? "(server stderr empty)" : String(tailLines)
        let message = """
        [MCPTestServer watchdog t=\(elapsedSeconds)s] alive — server stderr tail:
        \(tailDescription)
        [/watchdog]

        """
        // Write to test-process stderr so a live tail in CI sees it.
        fputs(message, stderr)
        fflush(stderr)
        // Also append to the per-instance log file. The "Dump MCP server stderr"
        // step cats this file post-mortem regardless of whether the test process
        // ever flushed its own stderr — so heartbeats survive even when the
        // GH Actions stderr capture is buffered/blocked behind a wedged test.
        if let handle = try? FileHandle(forWritingTo: stderrLogPath) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(message.utf8))
            try? handle.close()
        }
    }

    /// Poll the server's stderr log until it contains `needle`, up to `timeout`.
    /// On timeout, dumps the log via `Issue.record` and throws.
    /// Poll cadence mirrors CLIIntegrationTests/RunCommandTests.waitForStderrMatch (100ms).
    func awaitStderrContains(
        _ needle: String,
        timeout: Duration
    ) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if stderrLog().contains(needle) { return }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record(
            "Stderr did not contain \(needle.debugDescription) within \(timeout). Server stderr:\n\(stderrLog())"
        )
        throw MCPTestError.timedOut(operation: "awaitStderrContains(\(needle.debugDescription))", duration: timeout)
    }

    /// Poll `preview_elements` until the accessibility text contains `needle`,
    /// up to `timeout`, then return that text. The lightweight PreviewBanner
    /// registers in the a11y tree before the wrapped content, so a fixed sleep
    /// races the agent's render (#292).
    func awaitElementsText(
        sessionID: String,
        contains needle: String,
        timeout: Duration
    ) async throws -> String {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let (content, isError) = try await callTool(
                name: "preview_elements",
                arguments: ["sessionID": .string(sessionID), "filter": .string("all")]
            )
            let text = Self.extractText(from: content)
            if isError == true {
                throw MCPTestError.toolError(tool: "preview_elements", content: text)
            }
            if text.contains(needle) { return text }
            try await Task.sleep(for: .milliseconds(500))
        }
        Issue.record(
            "preview_elements did not contain \(needle.debugDescription) within \(timeout). Server stderr:\n\(stderrLog())"
        )
        throw MCPTestError.timedOut(
            operation: "awaitElementsText(contains: \(needle.debugDescription))", duration: timeout
        )
    }

    // MARK: - Snapshot helpers

    /// Capture a snapshot and return its raw image bytes. Decodes via the existing
    /// `extractImageData` helper; ignores mimeType (JPEG/PNG differ naturally across
    /// quality settings, but byte equality is sufficient for change-detection).
    ///
    /// The default budget must exceed the iOS product's worst-case snapshot
    /// fallback. When the live streamer surface briefly drops (e.g. the OS
    /// evicts and respawns the backgrounded iOS agent), `screenshot()` concedes
    /// to the one-shot `SBCaptureFramebuffer` path, whose IOSurface retry budget
    /// is ~33s (5×5s + 4×2s) before it even tries `simctl`. A 30s test timeout
    /// fired mid-fallback and killed the server; 60s lets the fallback complete.
    /// macOS snapshots return in well under a second, so the wider ceiling is
    /// free for them.
    func snapshotBytes(sessionID: String, timeout: Duration = .seconds(60)) async throws -> Data {
        let (content, isError) = try await callToolWithTimeout(
            name: "preview_snapshot",
            arguments: ["sessionID": .string(sessionID)],
            timeout: timeout
        )
        if isError == true {
            Issue.record("preview_snapshot returned an error. Content: \(Self.extractText(from: content))")
            throw MCPTestError.snapshotFailed
        }
        return try Self.extractImageData(from: content).data
    }

    /// Poll `preview_snapshot` until the returned bytes differ from `baseline`, up to `timeout`.
    /// Guards against false-positive passing tests where a reload silently no-ops and the
    /// pre-edit window pixels are returned unchanged.
    func awaitSnapshotChange(
        sessionID: String,
        baseline: Data,
        timeout: Duration
    ) async throws -> Data {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            let current = try await snapshotBytes(
                sessionID: sessionID,
                timeout: Self.remainingBudget(until: deadline)
            )
            if current != baseline { return current }
            try await Task.sleep(for: .milliseconds(200))
        }
        Issue.record("Snapshot bytes did not change within \(timeout). Server stderr:\n\(stderrLog())")
        throw MCPTestError.timedOut(operation: "awaitSnapshotChange(sessionID: \(sessionID))", duration: timeout)
    }

    private static func remainingBudget(
        until deadline: ContinuousClock.Instant
    ) -> Duration {
        let now = ContinuousClock.now
        guard now < deadline else { return .milliseconds(1) }
        return now.duration(to: deadline)
    }

    // MARK: - Timeout primitive

    /// Race `body` against a timer; throw `TestTimeoutSentinel` if the timer
    /// wins. Caller is expected to catch the sentinel and add operation-
    /// specific context.
    ///
    /// The timer runs on a detached kernel `Thread` (not Swift concurrency,
    /// not libdispatch), so it fires even when the cooperative thread pool
    /// is starved by a busy-spin elsewhere in the test process. The prior
    /// implementation used `withThrowingTaskGroup` + `Task.sleep(for:)` and
    /// went silent in exactly that scenario — see CI runs 72323677364 /
    /// 72328816376 (PR #133) and 72345678664 (PR #134) where a wedged
    /// daemon's `preview_snapshot` callTool continuation never resumed and
    /// the 30s internal timeout never threw, because the pool was pegged
    /// in the MCP SDK's AsyncThrowingStream loop.
    ///
    /// On timeout we terminate the server subprocess so the daemon-side
    /// state doesn't persist across tests. The body Task may remain
    /// suspended forever if its pending MCP continuation is never drained
    /// — the SDK's `Client.handleMessage(_:)` loop does not resume
    /// `pendingRequests` on transport EOF; only `Client.disconnect()`
    /// drains them. That's acceptable: the caller has already been
    /// resumed via `CheckedContinuation`, which is a synchronous primitive
    /// with no cooperative-pool dependency; the leaked Task dies with the
    /// test process. An exactly-once guard via `OSAllocatedUnfairLock`
    /// serializes the body vs. timeout race.
    static func withTimeout<T: Sendable>(
        _ duration: Duration,
        process: Process,
        _ body: @Sendable @escaping () async throws -> T
    ) async throws -> T {
        let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)
        return try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<T, Error>) in
            // Body path.
            Task {
                do {
                    let result = try await body()
                    resumed.withLock { done in
                        guard !done else { return }
                        done = true
                        continuation.resume(returning: result)
                    }
                } catch {
                    resumed.withLock { done in
                        guard !done else { return }
                        done = true
                        continuation.resume(throwing: error)
                    }
                }
            }

            // Timeout path — detached kernel thread, starvation-immune.
            let durationSeconds = duration.asTimeInterval
            Thread.detachNewThread {
                Thread.current.name = "MCPTestServer.withTimeout"
                Thread.sleep(forTimeInterval: durationSeconds)
                resumed.withLock { done in
                    guard !done else { return }
                    done = true
                    // Kill the subprocess so subsequent tests aren't polluted
                    // by a wedged daemon. `Process.terminate()` is a plain
                    // kill(2) syscall; safe from any thread.
                    process.terminate()
                    continuation.resume(throwing: TestTimeoutSentinel())
                }
            }
        }
    }
}

/// Internal sentinel thrown by `MCPTestServer.withTimeout`. Callers catch and
/// rethrow `MCPTestError.timedOut` with their own operation string.
private struct TestTimeoutSentinel: Error {}

enum MCPTestError: Error, LocalizedError {
    case noSessionID(String)
    case invalidBase64
    case noImageContent
    case noStructuredContent
    case cannotCreateStderrLog(String)
    case timedOut(operation: String, duration: Duration)
    case snapshotFailed
    case toolError(tool: String, content: String)

    var errorDescription: String? {
        switch self {
        case let .noSessionID(text): "No session ID found in: \(text)"
        case .invalidBase64: "Invalid base64 image data"
        case .noImageContent: "No image content in tool result"
        case .noStructuredContent: "No structuredContent in tool result"
        case let .cannotCreateStderrLog(path): "Could not open stderr log for writing at \(path)"
        case let .timedOut(operation, duration): "\(operation) timed out after \(duration)"
        case .snapshotFailed: "preview_snapshot returned isError=true"
        case let .toolError(tool, content): "\(tool) returned isError=true. Content: \(content)"
        }
    }
}

extension Duration {
    /// Seconds as a `TimeInterval`, for interop with Foundation APIs that
    /// predate `Duration` (`Thread.sleep(forTimeInterval:)`, timing math).
    var asTimeInterval: TimeInterval {
        Double(components.seconds) + Double(components.attoseconds) / 1e18
    }
}

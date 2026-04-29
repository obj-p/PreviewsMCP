import Foundation
import os

/// Raised by `runAsync` when a `timeout` is set and the subprocess outlives it.
/// The subprocess is SIGTERM'd and its pipes drained before this error is
/// thrown, so `capturedStdout` / `capturedStderr` contain whatever the child
/// managed to write before it was killed — useful for diagnosing *why* the
/// subprocess was stalled.
public struct AsyncProcessTimeout: Error, CustomStringConvertible {
    public let executable: String
    public let duration: Duration
    public let capturedStdout: String
    public let capturedStderr: String

    public var description: String {
        var parts = ["\(executable) exceeded timeout of \(duration)"]
        if !capturedStdout.isEmpty {
            parts.append("stdout before kill:\n\(capturedStdout)")
        }
        if !capturedStderr.isEmpty {
            parts.append("stderr before kill:\n\(capturedStderr)")
        }
        return parts.joined(separator: "; ")
    }
}

/// Result of an external process execution.
public struct ProcessOutput: Sendable {
    public let stdout: String
    public let stderr: String
    public let exitCode: Int32
}

/// Run an external process without blocking the caller's cooperative thread.
///
/// Uses `terminationHandler` + `withCheckedThrowingContinuation` so actor-isolated
/// callers don't block while waiting for the subprocess to exit.
///
/// - Parameters:
///   - executable: Absolute path to the executable.
///   - arguments: Arguments to pass.
///   - workingDirectory: Optional working directory for the process.
///   - discardStderr: If true, sends stderr to /dev/null.
///   - timeout: If set, the subprocess is SIGTERM'd and `AsyncProcessTimeout`
///     is thrown when this duration elapses. Use for tools that can legitimately
///     hang on misconfigured host state (e.g., `simctl io screenshot` against
///     a simulator with no attached display); do not set for tools whose
///     runtime is intrinsically unbounded (SPM/swiftc builds). Timer runs on
///     a GCD queue, independent of the Swift cooperative pool, so it fires
///     even when the calling process's concurrency is starved.
/// - Returns: A `ProcessOutput` with stdout/stderr strings and exit code.
public func runAsync(
    _ executable: String,
    arguments: [String] = [],
    workingDirectory: URL? = nil,
    discardStderr: Bool = false,
    timeout: Duration? = nil
) async throws -> ProcessOutput {
    try await withCheckedThrowingContinuation { continuation in
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        if let wd = workingDirectory {
            process.currentDirectoryURL = wd
        }

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe

        let stderrPipe: Pipe?
        if discardStderr {
            process.standardError = FileHandle.nullDevice
            stderrPipe = nil
        } else {
            let pipe = Pipe()
            process.standardError = pipe
            stderrPipe = pipe
        }

        // Read pipes on background threads to avoid deadlock.
        // If the child writes more than the pipe buffer (~64KB), it blocks
        // until the parent reads. Using readDataToEndOfFile() on background
        // threads drains the pipes concurrently while the process runs.
        // The DispatchGroup ensures all data is collected before
        // terminationHandler reads it — avoiding a race where the
        // continuation resumes before pipe data has been captured.
        let stdoutData = UnsafeSendableBox<Data>()
        let stderrData = UnsafeSendableBox<Data>()
        let pipeGroup = DispatchGroup()

        pipeGroup.enter()
        DispatchQueue.global().async {
            stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            pipeGroup.leave()
        }

        if let stderrPipe {
            pipeGroup.enter()
            DispatchQueue.global().async {
                stderrData.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                pipeGroup.leave()
            }
        }

        // Exactly-once guard shared between termination and timeout paths.
        // If both fire (terminate triggers terminationHandler which races the
        // timeout timer), whichever wins resumes the continuation; the other
        // no-ops.
        let resumed = OSAllocatedUnfairLock<Bool>(initialState: false)

        // Timeout timer runs on a GCD queue (not the Swift cooperative pool),
        // so it fires even when the calling process's concurrency is under
        // heavy load. When it fires, we SIGTERM the subprocess, wait for the
        // pipe drains to finish (so whatever the child wrote before being
        // killed lands in the captured stdout/stderr), then resume with the
        // captured data attached to the error. That lets callers diagnose
        // *why* the subprocess was stalled instead of just "it hung."
        //
        // The subprocess's terminationHandler also fires from the terminate
        // below, but sees `resumed == true` and no-ops.
        let timeoutSource: DispatchSourceTimer? = timeout.map { duration in
            let source = DispatchSource.makeTimerSource(
                queue: DispatchQueue.global(qos: .userInitiated))
            let seconds =
                Double(duration.components.seconds)
                + Double(duration.components.attoseconds) / 1e18
            source.schedule(deadline: .now() + seconds)
            source.setEventHandler {
                let shouldResume = resumed.withLock { done -> Bool in
                    guard !done else { return false }
                    done = true
                    return true
                }
                guard shouldResume else { return }
                // SIGTERM first — gives the child a chance to flush stdio
                // buffers on its way out.
                process.terminate()

                // Escalate to SIGKILL if SIGTERM doesn't bring the child down
                // within 2s. Observed on PR #141 CI: `simctl io screenshot`
                // stuck in a kernel syscall ignored SIGTERM entirely — the
                // child's pipe-write fds stayed open, the background
                // readDataToEndOfFile threads blocked on EOF that never came,
                // and pipeGroup.wait() below hung indefinitely. SIGKILL is
                // unignorable; the kernel reaps the process and closes its
                // fds, which unblocks the readers.
                DispatchQueue.global(qos: .userInitiated).asyncAfter(
                    deadline: .now() + 2
                ) {
                    if process.isRunning {
                        Foundation.kill(process.processIdentifier, SIGKILL)
                    }
                }

                // Also bound the pipe drain itself so a totally-stuck fd
                // doesn't strand the continuation. Whatever we have captured
                // so far is attached to the AsyncProcessTimeout error.
                _ = pipeGroup.wait(timeout: .now() + .seconds(10))
                let capturedStdout = (String(data: stdoutData.value, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let capturedStderr = String(data: stderrData.value, encoding: .utf8) ?? ""
                continuation.resume(
                    throwing: AsyncProcessTimeout(
                        executable: executable,
                        duration: duration,
                        capturedStdout: capturedStdout,
                        capturedStderr: capturedStderr))
            }
            source.resume()
            return source
        }

        process.terminationHandler = { proc in
            // Wait for pipe reads to finish before reading collected data
            pipeGroup.wait()

            let shouldResume = resumed.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            guard shouldResume else { return }
            timeoutSource?.cancel()

            let stdout = (String(data: stdoutData.value, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(data: stderrData.value, encoding: .utf8) ?? ""

            continuation.resume(
                returning: ProcessOutput(
                    stdout: stdout,
                    stderr: stderr,
                    exitCode: proc.terminationStatus
                ))
        }

        do {
            try process.run()
        } catch {
            let shouldResume = resumed.withLock { done -> Bool in
                guard !done else { return false }
                done = true
                return true
            }
            if shouldResume {
                timeoutSource?.cancel()
                continuation.resume(throwing: error)
            }
        }
    }
}

/// Thread-safe mutable data buffer for collecting pipe output across callbacks.
private final class UnsafeSendableBox<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var _value: Data = Data()

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

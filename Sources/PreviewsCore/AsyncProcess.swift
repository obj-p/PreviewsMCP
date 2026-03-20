import Foundation

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
/// - Returns: A `ProcessOutput` with stdout/stderr strings and exit code.
public func runAsync(
    _ executable: String,
    arguments: [String] = [],
    workingDirectory: URL? = nil,
    discardStderr: Bool = false
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

        process.terminationHandler = { proc in
            // Wait for pipe reads to finish before reading collected data
            pipeGroup.wait()

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
            continuation.resume(throwing: error)
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

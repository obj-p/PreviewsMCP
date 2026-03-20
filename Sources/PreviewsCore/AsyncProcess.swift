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

        // Read pipe data eagerly on background threads to avoid deadlock.
        // If the child writes more than the pipe buffer (~64KB), it blocks
        // until the parent reads. Reading in terminationHandler would deadlock
        // because termination waits for the child to exit first.
        let stdoutData = UnsafeSendableBox<Data>()
        let stderrData = UnsafeSendableBox<Data>()

        stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
            } else {
                stdoutData.append(chunk)
            }
        }

        if let stderrPipe {
            stderrPipe.fileHandleForReading.readabilityHandler = { handle in
                let chunk = handle.availableData
                if chunk.isEmpty {
                    stderrPipe.fileHandleForReading.readabilityHandler = nil
                } else {
                    stderrData.append(chunk)
                }
            }
        }

        process.terminationHandler = { proc in
            // Drain any remaining data after process exits
            stdoutData.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
            stderrData.append(stderrPipe?.fileHandleForReading.readDataToEndOfFile() ?? Data())

            let stdout = (String(data: stdoutData.value, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = String(data: stderrData.value, encoding: .utf8) ?? ""

            continuation.resume(returning: ProcessOutput(
                stdout: stdout,
                stderr: stderr,
                exitCode: proc.terminationStatus
            ))
        }

        do {
            try process.run()
        } catch {
            stdoutPipe.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
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

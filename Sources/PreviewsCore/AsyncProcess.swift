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

        process.terminationHandler = { proc in
            let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
            let stderrData = stderrPipe?.fileHandleForReading.readDataToEndOfFile()
            let stdout = (String(data: stdoutData, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let stderr = stderrData.flatMap { String(data: $0, encoding: .utf8) } ?? ""

            continuation.resume(returning: ProcessOutput(
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

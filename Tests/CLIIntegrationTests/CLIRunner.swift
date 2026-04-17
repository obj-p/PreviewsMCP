import Foundation
import Testing

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

    // MARK: - Process runner

    /// Run `previewsmcp` with the given subcommand and arguments.
    static func run(
        _ subcommand: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> CLIResult {
        try #require(
            FileManager.default.fileExists(atPath: binaryPath),
            "previewsmcp binary not found at \(binaryPath). Run 'swift build' first."
        )
        return try await runProcess(
            binaryPath,
            arguments: [subcommand] + arguments,
            workingDirectory: workingDirectory
        )
    }

    /// Check if a command-line tool is available on PATH.
    static func toolAvailable(_ name: String) async -> Bool {
        let result = try? await runProcess("/usr/bin/which", arguments: [name])
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

    /// Run an arbitrary external process (not the CLI binary).
    static func runExternal(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> CLIResult {
        try await runProcess(executable, arguments: arguments, workingDirectory: workingDirectory)
    }

    // MARK: - Private process helper

    private static func runProcess(
        _ executable: String,
        arguments: [String] = [],
        workingDirectory: URL? = nil
    ) async throws -> CLIResult {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            if let wd = workingDirectory {
                process.currentDirectoryURL = wd
            }

            let stdoutPipe = Pipe()
            let stderrPipe = Pipe()
            process.standardOutput = stdoutPipe
            process.standardError = stderrPipe

            // Read pipes on background threads to avoid deadlock with large output.
            let stdoutBox = LockedData()
            let stderrBox = LockedData()
            let group = DispatchGroup()

            group.enter()
            DispatchQueue.global().async {
                stdoutBox.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }

            group.enter()
            DispatchQueue.global().async {
                stderrBox.append(stderrPipe.fileHandleForReading.readDataToEndOfFile())
                group.leave()
            }

            process.terminationHandler = { proc in
                group.wait()
                let stdout = (String(data: stdoutBox.value, encoding: .utf8) ?? "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let stderr = String(data: stderrBox.value, encoding: .utf8) ?? ""
                continuation.resume(
                    returning: CLIResult(
                        stdout: stdout, stderr: stderr, exitCode: proc.terminationStatus))
            }

            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
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

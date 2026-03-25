import Foundation
import MCP
import System
import Testing

/// Manages a `previewsmcp serve` subprocess with an MCP Client connected via stdio pipes.
final class MCPTestServer: @unchecked Sendable {

    // MARK: - Paths

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MCPIntegrationTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root

    static let binaryPath: String =
        repoRoot.appendingPathComponent(".build/debug/previewsmcp").path

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
    private let stderrPipe: Pipe

    private init(process: Process, client: Client, stdinPipe: Pipe, stdoutPipe: Pipe, stderrPipe: Pipe) {
        self.process = process
        self.client = client
        self.stdinPipe = stdinPipe
        self.stdoutPipe = stdoutPipe
        self.stderrPipe = stderrPipe
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

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        let readFD = FileDescriptor(rawValue: stdoutPipe.fileHandleForReading.fileDescriptor)
        let writeFD = FileDescriptor(rawValue: stdinPipe.fileHandleForWriting.fileDescriptor)
        let transport = StdioTransport(input: readFD, output: writeFD)

        let client = Client(name: "mcp-integration-test", version: "1.0")
        _ = try await client.connect(transport: transport)

        return MCPTestServer(
            process: process, client: client,
            stdinPipe: stdinPipe, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe
        )
    }

    /// Disconnect client and terminate subprocess.
    func stop() async {
        try? await client.disconnect()
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    // MARK: - Tool calls

    /// Call an MCP tool and return the result.
    func callTool(
        name: String,
        arguments: [String: Value]? = nil
    ) async throws -> (content: [Tool.Content], isError: Bool?) {
        try await client.callTool(name: name, arguments: arguments)
    }

    // MARK: - Response helpers

    /// Extract all text content from a tool result, joined by newlines.
    static func extractText(from content: [Tool.Content]) -> String {
        content.compactMap { item in
            if case .text(let text) = item { return text }
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
            if case .image(let base64, let mimeType, _) = item {
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

    /// Read width and height from PNG IHDR chunk (bytes 16-23, big-endian uint32).
    static func pngDimensions(_ data: Data) -> (width: Int, height: Int) {
        guard data.count >= 24 else { return (0, 0) }
        let w = Int(data[16]) << 24 | Int(data[17]) << 16 | Int(data[18]) << 8 | Int(data[19])
        let h = Int(data[20]) << 24 | Int(data[21]) << 16 | Int(data[22]) << 8 | Int(data[23])
        return (w, h)
    }

    /// Get stderr output (for debugging).
    func stderrOutput() -> String {
        let data = stderrPipe.fileHandleForReading.availableData
        return String(data: data, encoding: .utf8) ?? ""
    }
}

enum MCPTestError: Error, LocalizedError {
    case noSessionID(String)
    case invalidBase64
    case noImageContent

    var errorDescription: String? {
        switch self {
        case .noSessionID(let text): "No session ID found in: \(text)"
        case .invalidBase64: "Invalid base64 image data"
        case .noImageContent: "No image content in tool result"
        }
    }
}

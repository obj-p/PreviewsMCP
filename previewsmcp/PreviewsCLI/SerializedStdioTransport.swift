import Foundation
import Logging
import PreviewsCore
import MCP
import System

/// A stdio JSON-RPC transport whose `send`s cannot interleave.
///
/// The SDK's `StdioTransport` (v0.7.x) is an actor, but its `send` retries
/// `EAGAIN` on the non-blocking pipe with `await Task.sleep` — and actor
/// re-entrancy admits a second `send` at that suspension point. Any response
/// larger than the pipe buffer (every base64 snapshot/variants payload) that
/// backs up mid-write can therefore have another message (the daemon's 2s
/// heartbeat notification, a progress notification) spliced into its bytes,
/// corrupting the newline framing; the client drops what it can't decode and
/// the caller times out with no error on either side (#320's callTool-stall
/// face). This transport chains each `send` behind the previous one, so a
/// message's bytes always land contiguously. Everything else mirrors the
/// SDK transport (MIT, github.com/modelcontextprotocol/swift-sdk); drop this
/// once upstream serializes its writes.
actor SerializedStdioTransport: Transport {
    nonisolated let logger: Logger

    private let input: FileDescriptor
    private let output: FileDescriptor
    private var isConnected = false
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var sendChain: Task<Void, Swift.Error>?

    init(
        input: FileDescriptor = FileDescriptor.standardInput,
        output: FileDescriptor = FileDescriptor.standardOutput
    ) {
        self.input = input
        self.output = output
        // No-op handler, as in the SDK original: the SDK Server logs through
        // the transport's logger, and swift-log's default factory writes to
        // STDOUT — plain text spliced into the JSON-RPC stream on any SDK
        // error path, the exact corruption class this transport exists to
        // prevent.
        logger = Logger(
            label: "previewsmcp.serialized-stdio-transport",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )

        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream { continuation = $0 }
        messageContinuation = continuation
    }

    func connect() async throws {
        guard !isConnected else { return }
        try setNonBlocking(fileDescriptor: input)
        try setNonBlocking(fileDescriptor: output)
        isConnected = true
        Task {
            await readLoop()
        }
    }

    private func setNonBlocking(fileDescriptor: FileDescriptor) throws {
        let flags = fcntl(fileDescriptor.rawValue, F_GETFL)
        guard flags >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
        let result = fcntl(fileDescriptor.rawValue, F_SETFL, flags | O_NONBLOCK)
        guard result >= 0 else {
            throw MCPError.transportError(Errno(rawValue: CInt(errno)))
        }
    }

    private func readLoop() async {
        let bufferSize = 4096
        var buffer = [UInt8](repeating: 0, count: bufferSize)
        var pendingData = Data()

        while isConnected, !Task.isCancelled {
            do {
                let bytesRead = try buffer.withUnsafeMutableBufferPointer { pointer in
                    try input.read(into: UnsafeMutableRawBufferPointer(pointer))
                }
                if bytesRead == 0 {
                    break
                }
                pendingData.append(Data(buffer[..<bytesRead]))
                while let newlineIndex = pendingData.firstIndex(of: UInt8(ascii: "\n")) {
                    let messageData = pendingData[..<newlineIndex]
                    pendingData = pendingData[(newlineIndex + 1)...]
                    if !messageData.isEmpty {
                        messageContinuation.yield(Data(messageData))
                    }
                }
            } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                try? await Task.sleep(for: .milliseconds(10))
                continue
            } catch {
                if !Task.isCancelled {
                    Log.warn("stdio transport read error: \(error)")
                }
                break
            }
        }
        messageContinuation.finish()
    }

    func disconnect() async {
        guard isConnected else { return }
        isConnected = false
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        guard isConnected else {
            throw MCPError.transportError(Errno(rawValue: ENOTCONN))
        }

        // Chain behind the previous send. Actor isolation alone cannot
        // provide this: the EAGAIN retry below suspends, and a re-entrant
        // send would otherwise interleave its bytes there. A failed
        // predecessor doesn't fail this message — each send stands alone
        // once it holds the head of the chain.
        let previous = sendChain
        let task = Task { [output] in
            _ = try? await previous?.value
            var messageWithNewline = message
            messageWithNewline.append(UInt8(ascii: "\n"))
            var remaining = messageWithNewline

            while !remaining.isEmpty {
                do {
                    let written = try remaining.withUnsafeBytes { buffer in
                        try output.write(UnsafeRawBufferPointer(buffer))
                    }
                    if written > 0 {
                        remaining = remaining.dropFirst(written)
                    }
                } catch let error where MCPError.isResourceTemporarilyUnavailable(error) {
                    try await Task.sleep(for: .milliseconds(10))
                    continue
                } catch {
                    throw MCPError.transportError(error)
                }
            }
        }
        sendChain = task
        try await task.value
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }
}

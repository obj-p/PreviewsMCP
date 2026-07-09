import Foundation
import Logging
import MCP
import System

/// In-house newline-framed JSON-RPC stdio transport (rewrite stage 2).
///
/// Replaces the SDK's `StdioTransport` and the `SerializedStdioTransport`
/// wrapper at cutover, fixing their defect class by construction:
///
/// - Sends are chained, never concurrent: there is no suspension between
///   reading and updating `sendChain`, so re-entrant callers each queue
///   behind the true predecessor and frames land contiguously (#320).
/// - Read errors PROPAGATE: a real errno finishes the receive stream
///   throwing, EOF finishes it cleanly, and EINTR is retried — the SDK
///   broke its loop silently on both.
/// - The logger is a no-op by construction, so nothing can write prose
///   into the JSON stream the daemon serves on stdout.
///
/// The transport does not own its file descriptors and never closes them.
actor FramedStdioTransport: Transport {
    nonisolated let logger = Logger(
        label: "previewsmcp.framed-stdio",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let input: FileDescriptor
    private let output: FileDescriptor
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var sendChain: Task<Void, Swift.Error>?
    private var pendingSends: Set<Task<Void, Swift.Error>> = []
    private var reader: Task<Void, Never>?

    init(
        input: FileDescriptor = .standardInput,
        output: FileDescriptor = .standardOutput
    ) {
        self.input = input
        self.output = output
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream { continuation = $0 }
        messageContinuation = continuation
    }

    func connect() async throws {
        try Self.setNonBlocking(input)
        try Self.setNonBlocking(output)
        reader = Task { await readLoop() }
    }

    func disconnect() async {
        // Cancel every queued/in-flight send, not just the chain tail: a
        // peer that stops draining leaves the head send retrying EAGAIN
        // forever, and everything queued behind it retains its message.
        for task in pendingSends {
            task.cancel()
        }
        pendingSends.removeAll()
        sendChain = nil
        reader?.cancel()
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        var frame = message
        frame.append(UInt8(ascii: "\n"))
        // No suspension between reading and updating `sendChain` — the
        // serialization invariant everything above depends on.
        let previous = sendChain
        let task = Task { [output] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await Self.write(frame, to: output)
        }
        sendChain = task
        pendingSends.insert(task)
        defer { pendingSends.remove(task) }
        // Forward the caller's cancellation so a cancelled caller doesn't
        // leave its write retrying forever.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }

    // MARK: - Read side

    private func readLoop() async {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !Task.isCancelled {
            do {
                let count = try chunk.withUnsafeMutableBytes { try input.read(into: $0) }
                if count == 0 {
                    messageContinuation.finish()
                    return
                }
                buffer.append(contentsOf: chunk[0 ..< count])
                while let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex ..< newline]
                    if !line.isEmpty {
                        messageContinuation.yield(Data(line))
                    }
                    buffer = Data(buffer[buffer.index(after: newline)...])
                }
                // Keep the actor fair to senders during sustained input.
                await Task.yield()
            } catch let errno as Errno {
                switch errno {
                case .wouldBlock, .resourceTemporarilyUnavailable:
                    do {
                        try await Task.sleep(for: .milliseconds(10))
                    } catch {
                        messageContinuation.finish()
                        return
                    }
                case .interrupted:
                    continue
                default:
                    messageContinuation.finish(throwing: errno)
                    return
                }
            } catch {
                messageContinuation.finish(throwing: error)
                return
            }
        }
        messageContinuation.finish()
    }

    // MARK: - Write side

    /// Static so the retry suspension never suspends the actor mid-write;
    /// ordering comes from the send chain, not isolation.
    private static func write(_ data: Data, to output: FileDescriptor) async throws {
        var offset = 0
        while offset < data.count {
            do {
                let written = try data.withUnsafeBytes { raw in
                    try output.write(UnsafeRawBufferPointer(rebasing: raw[offset...]))
                }
                offset += written
            } catch let errno as Errno {
                switch errno {
                case .wouldBlock, .resourceTemporarilyUnavailable:
                    try await Task.sleep(for: .milliseconds(10))
                case .interrupted:
                    continue
                default:
                    throw errno
                }
            }
        }
    }

    private static func setNonBlocking(_ descriptor: FileDescriptor) throws {
        let flags = fcntl(descriptor.rawValue, F_GETFL)
        guard flags >= 0 else { throw Errno(rawValue: errno) }
        guard fcntl(descriptor.rawValue, F_SETFL, flags | O_NONBLOCK) >= 0 else {
            throw Errno(rawValue: errno)
        }
    }
}

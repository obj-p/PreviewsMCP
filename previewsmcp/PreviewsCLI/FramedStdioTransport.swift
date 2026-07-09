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
/// The transport does not own its file descriptors and never closes them,
/// but `connect()` switches both to non-blocking and leaves them that way.
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
        reader = Task { [input, messageContinuation] in
            await Self.readLoop(input: input, continuation: messageContinuation)
        }
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
        // No suspension between reading and updating `sendChain` — the
        // serialization invariant everything above depends on. The newline
        // goes out as its own write rather than appending to `message`,
        // which would copy every multi-hundred-KB frame just to add a byte.
        let previous = sendChain
        let task = Task { [output] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await Self.write(message, to: output)
            try await Self.write(Self.newlineFrame, to: output)
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

    /// Static like `write`: it touches no actor state, so running it
    /// isolated would only make senders and the reader contend.
    private static func readLoop(
        input: FileDescriptor,
        continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    ) async {
        var buffer = Data()
        var scanFrom = buffer.startIndex
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while !Task.isCancelled {
            do {
                let count = try chunk.withUnsafeMutableBytes { try input.read(into: $0) }
                if count == 0 {
                    continuation.finish()
                    return
                }
                chunk.withUnsafeBytes { raw in
                    buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[0 ..< count]))
                }
                // `scanFrom` marks how far the newline scan has gotten, so
                // a large frame arriving in many chunks is scanned once,
                // not once per chunk; slicing instead of re-wrapping in
                // Data() keeps frame extraction copy-free.
                while let newline = buffer[scanFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex ..< newline]
                    if !line.isEmpty {
                        continuation.yield(Data(line))
                    }
                    buffer = buffer[buffer.index(after: newline)...]
                    scanFrom = buffer.startIndex
                }
                scanFrom = buffer.endIndex
                if buffer.isEmpty {
                    buffer = Data()
                    scanFrom = buffer.startIndex
                }
            } catch let errno as Errno {
                switch errno {
                case .wouldBlock, .resourceTemporarilyUnavailable:
                    try? await Task.sleep(for: pollInterval)
                case .interrupted:
                    continue
                default:
                    continuation.finish(throwing: errno)
                    return
                }
            } catch {
                continuation.finish(throwing: error)
                return
            }
        }
        continuation.finish()
    }

    // MARK: - Write side

    private static let newlineFrame = Data([UInt8(ascii: "\n")])
    private static let pollInterval: Duration = .milliseconds(10)

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
                    try await Task.sleep(for: pollInterval)
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

import Foundation
import Logging
import MCP
import os
import System

enum FramedTransportError: Swift.Error, Equatable {
    case disconnected
    case poisoned
    case truncatedFinalFrame
}

/// In-house newline-framed JSON-RPC transport over plain file descriptors
/// (rewrite stages 2-3): stdio for the MCP channel, a Unix domain socket
/// for the daemon channel (see `DaemonSocket`).
///
/// Replaces the SDK's `StdioTransport`, the `SerializedStdioTransport`
/// wrapper, and `NetworkTransport` at cutover, fixing their defect classes
/// by construction:
///
/// - Sends are chained, never concurrent: there is no suspension between
///   reading and updating `sendChain`, so re-entrant callers each queue
///   behind the true predecessor and frames land contiguously (#320).
/// - A started frame always finishes: caller cancellation is NOT forwarded
///   into an in-flight write, because aborting mid-frame leaves partial
///   bytes on the wire that would corrupt every later frame. Only
///   `disconnect()` aborts writes, and any write that fails or aborts
///   poisons the transport so later sends fail loudly instead of gluing
///   onto a torn frame.
/// - Read errors PROPAGATE: a real errno finishes the receive stream
///   throwing, EOF with a buffered partial frame finishes it throwing
///   `truncatedFinalFrame`, clean EOF finishes it cleanly, and EINTR is
///   retried — the SDK broke its loop silently on all of these.
/// - The logger is a no-op by construction, so nothing can write prose
///   into the JSON stream the daemon serves on stdout.
///
/// The transport does not own its file descriptors and never closes them,
/// but `connect()` switches both to non-blocking, disables SIGPIPE delivery
/// on the output (a dead peer surfaces as EPIPE, not process death), and
/// leaves both that way. `disconnect()` returns only after the read loop
/// and every send task have finished, so an owner may close the
/// descriptors immediately afterwards without racing them.
actor FramedTransport: Transport {
    nonisolated let logger = Logger(
        label: "previewsmcp.framed-transport",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private let input: FileDescriptor
    private let output: FileDescriptor
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var sendChain: Task<Void, Swift.Error>?
    private var pendingSends: Set<Task<Void, Swift.Error>> = []
    private var reader: Task<Void, Never>?
    private var isDisconnected = false
    private let poisoned = OSAllocatedUnfairLock(initialState: false)

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

    init(socket: FileDescriptor) {
        self.init(input: socket, output: socket)
    }

    func connect() async throws {
        try input.setNonBlocking()
        if output.rawValue != input.rawValue {
            try output.setNonBlocking()
        }
        try output.setNoSigPipe()
        reader = Task { [input, messageContinuation] in
            await Self.readLoop(input: input, continuation: messageContinuation)
        }
    }

    func disconnect() async {
        guard !isDisconnected else { return }
        isDisconnected = true
        // Cancel every queued/in-flight send, not just the chain tail: a
        // peer that stops draining leaves the head send retrying EAGAIN
        // forever, and everything queued behind it retains its message.
        let sends = pendingSends
        for task in sends {
            task.cancel()
        }
        pendingSends.removeAll()
        sendChain = nil
        reader?.cancel()
        // Rendezvous with everything that touches the descriptors before
        // returning: the owner may close them the moment we're done.
        for task in sends {
            _ = try? await task.value
        }
        await reader?.value
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        guard !isDisconnected else { throw FramedTransportError.disconnected }
        // No suspension between reading and updating `sendChain` — the
        // serialization invariant everything above depends on.
        let previous = sendChain
        let task = Task { [output, poisoned] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            guard !poisoned.withLock({ $0 }) else {
                throw FramedTransportError.poisoned
            }
            do {
                try await Self.writeFrame(message, to: output)
            } catch {
                poisoned.withLock { $0 = true }
                throw error
            }
        }
        sendChain = task
        pendingSends.insert(task)
        defer { pendingSends.remove(task) }
        try await task.value
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
                    if buffer.isEmpty {
                        continuation.finish()
                    } else {
                        continuation.finish(
                            throwing: FramedTransportError.truncatedFinalFrame
                        )
                    }
                    return
                }
                chunk.withUnsafeBytes { raw in
                    buffer.append(contentsOf: UnsafeRawBufferPointer(rebasing: raw[0 ..< count]))
                }
                // `scanFrom` marks how far the newline scan has gotten, so
                // a large frame arriving in many chunks is scanned once,
                // not once per chunk; frame extraction slices (no copy),
                // then one compaction per iteration that extracted frames
                // releases the consumed prefix's backing storage.
                let preExtraction = buffer.startIndex
                while let newline = buffer[scanFrom...].firstIndex(of: UInt8(ascii: "\n")) {
                    let line = buffer[buffer.startIndex ..< newline]
                    if !line.isEmpty {
                        continuation.yield(Data(line))
                    }
                    buffer = buffer[buffer.index(after: newline)...]
                    scanFrom = buffer.startIndex
                }
                if buffer.startIndex != preExtraction {
                    buffer = Data(buffer)
                }
                scanFrom = buffer.endIndex
            } catch let errno as Errno {
                switch errno {
                case .wouldBlock:
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

    private static let pollInterval: Duration = .milliseconds(10)

    /// Static so the retry suspension never suspends the actor mid-write;
    /// ordering comes from the send chain, not isolation. One `writev` per
    /// attempt carries payload + newline: no payload copy, no second
    /// syscall for the delimiter.
    private static func writeFrame(_ payload: Data, to output: FileDescriptor) async throws {
        var offset = 0
        let total = payload.count + 1
        while offset < total {
            try Task.checkCancellation()
            do {
                offset += try writeFrameChunk(payload, from: offset, to: output)
            } catch let errno as Errno {
                switch errno {
                case .wouldBlock:
                    try await Task.sleep(for: pollInterval)
                case .interrupted:
                    continue
                default:
                    throw errno
                }
            }
        }
    }

    private static func writeFrameChunk(
        _ payload: Data, from offset: Int, to output: FileDescriptor
    ) throws -> Int {
        var newline = UInt8(ascii: "\n")
        return try payload.withUnsafeBytes { raw in
            try withUnsafeMutableBytes(of: &newline) { newlineRaw in
                var vectors = [iovec]()
                if offset < payload.count {
                    vectors.append(iovec(
                        iov_base: UnsafeMutableRawPointer(
                            mutating: raw.baseAddress!.advanced(by: offset)
                        ),
                        iov_len: payload.count - offset
                    ))
                }
                vectors.append(iovec(iov_base: newlineRaw.baseAddress, iov_len: 1))
                let written = writev(output.rawValue, &vectors, Int32(vectors.count))
                guard written >= 0 else { throw Errno(rawValue: errno) }
                return written
            }
        }
    }
}

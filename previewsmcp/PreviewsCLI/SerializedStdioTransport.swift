import Foundation
import Logging
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
/// face). This wrapper chains each `send` behind the previous one, so the
/// inner transport never runs two sends concurrently and every frame lands
/// contiguously. Drop once upstream serializes its writes.
actor SerializedStdioTransport: Transport {
    nonisolated let logger: Logger

    private let inner: StdioTransport
    private let messageStream: AsyncThrowingStream<Data, Swift.Error>
    private let messageContinuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private var sendChain: Task<Void, Swift.Error>?
    private var pendingSends: Set<Task<Void, Swift.Error>> = []
    private var pump: Task<Void, Never>?

    init(
        input: FileDescriptor = FileDescriptor.standardInput,
        output: FileDescriptor = FileDescriptor.standardOutput
    ) {
        inner = StdioTransport(input: input, output: output)
        logger = Logger(
            label: "previewsmcp.serialized-stdio-transport",
            factory: { _ in SwiftLogNoOpLogHandler() }
        )
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        messageStream = AsyncThrowingStream { continuation = $0 }
        messageContinuation = continuation
    }

    func connect() async throws {
        try await inner.connect()
        // `Transport.receive()` is a synchronous requirement, so this actor
        // cannot forward it to the inner actor on demand — pump the inner
        // stream into our own instead.
        pump = Task { [inner, messageContinuation] in
            do {
                for try await message in await inner.receive() {
                    messageContinuation.yield(message)
                }
                messageContinuation.finish()
            } catch {
                messageContinuation.finish(throwing: error)
            }
        }
    }

    func disconnect() async {
        // Cancel every queued/in-flight send, not just the chain tail: a
        // client that stops draining stdout leaves the head send retrying
        // EAGAIN forever, and each 2s heartbeat queued behind it retains its
        // full message. Cancellation surfaces inside the inner transport's
        // EAGAIN retry via its throwing Task.sleep.
        for task in pendingSends {
            task.cancel()
        }
        pendingSends.removeAll()
        sendChain = nil
        pump?.cancel()
        await inner.disconnect()
        messageContinuation.finish()
    }

    func send(_ message: Data) async throws {
        // Chain behind the previous send; actor isolation alone cannot
        // prevent interleaving because the inner send suspends mid-write.
        // There is no suspension between reading and updating `sendChain`,
        // so re-entrant callers each chain behind the true predecessor. A
        // failed or cancelled predecessor doesn't fail this message.
        let previous = sendChain
        let task = Task { [inner] in
            _ = try? await previous?.value
            try Task.checkCancellation()
            try await inner.send(message)
        }
        sendChain = task
        pendingSends.insert(task)
        defer { pendingSends.remove(task) }
        // Forward the caller's cancellation to the chained task so a
        // cancelled caller doesn't leave its write retrying forever.
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        messageStream
    }
}

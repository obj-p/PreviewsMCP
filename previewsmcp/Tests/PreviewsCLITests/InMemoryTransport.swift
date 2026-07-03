import Foundation
import Logging
import MCP

/// A connected pair of in-memory `Transport`s for characterizing the SDK
/// Server and Client without processes, pipes, or sockets. Each `send`
/// arrives whole on the peer's `receive()` stream — one message per yield,
/// the same framing the SDK's own transports produce after their newline
/// split. `sentFrames` captures the exact bytes a side produced, for
/// wire-shape assertions.
actor InMemoryTransport: Transport {
    nonisolated let logger = Logger(
        label: "test.inmemory",
        factory: { _ in SwiftLogNoOpLogHandler() }
    )

    private weak var peer: InMemoryTransport?
    private let stream: AsyncThrowingStream<Data, Swift.Error>
    private let continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation
    private(set) var sentFrames: [Data] = []

    init() {
        var continuation: AsyncThrowingStream<Data, Swift.Error>.Continuation!
        stream = AsyncThrowingStream { continuation = $0 }
        self.continuation = continuation
    }

    /// Two transports wired to each other. Keep both alive for the test's
    /// duration — the peer reference is weak.
    static func pair() async -> (InMemoryTransport, InMemoryTransport) {
        let a = InMemoryTransport()
        let b = InMemoryTransport()
        await a.setPeer(b)
        await b.setPeer(a)
        return (a, b)
    }

    private func setPeer(_ transport: InMemoryTransport) {
        peer = transport
    }

    func connect() async throws {}

    func disconnect() async {
        continuation.finish()
        await peer?.peerDisconnected()
    }

    private func peerDisconnected() {
        continuation.finish()
    }

    func send(_ data: Data) async throws {
        sentFrames.append(data)
        await peer?.deliver(data)
    }

    private func deliver(_ data: Data) {
        continuation.yield(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        stream
    }
}

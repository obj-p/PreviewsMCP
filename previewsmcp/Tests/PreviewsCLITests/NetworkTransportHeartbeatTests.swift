import Foundation
import MCP
import Network
import os
import PreviewsCLI
import PreviewsTestSupport
import Testing

/// Documents why every test-side SDK `NetworkTransport` on the daemon
/// channel must be constructed with `heartbeatConfig: .disabled` (production
/// rides `FramedTransport` and constructs none): the SDK sends heartbeats
/// WITHOUT the newline
/// delimiter its messages use, and its receive loop classifies whole read
/// chunks — a chunk that starts with the 4 heartbeat magic bytes is discarded
/// entirely, so a JSON-RPC message coalesced into the same read as a preceding
/// heartbeat is silently lost. The classification is unconditional, so a
/// receiver cannot defend itself; the only safe topology is one where no peer
/// emits transport-level heartbeats.
@Suite("NetworkTransport heartbeat framing")
struct NetworkTransportHeartbeatTests {
    @Test("a message coalesced behind a heartbeat is silently dropped")
    func coalescedHeartbeatDropsTheMessageBehindIt() async throws {
        let socketPath = try makeSocketPath()
        defer { removeSocketDirectory(socketPath) }

        let params = NWParameters.tcp
        params.requiredLocalEndpoint = NWEndpoint.unix(path: socketPath)
        let listener = try NWListener(using: params)

        let accepted = OSAllocatedUnfairLock(initialState: NWConnection?.none)
        listener.newConnectionHandler = { connection in
            accepted.withLock { $0 = connection }
        }
        try await awaitListenerReady(listener)
        defer { listener.cancel() }

        let rawPeer = NWConnection(to: .unix(path: socketPath), using: .tcp)
        try await awaitReady(rawPeer)
        defer { rawPeer.cancel() }

        let serverSide = try await pollUntil(
            { accepted.withLock { $0 } },
            failure: "listener never accepted the connection"
        )
        let transport = daemonChannelTransport(connection: serverSide)
        try await transport.connect()

        let received = OSAllocatedUnfairLock(initialState: [Data]())
        let collector = Task {
            for try await message in await transport.receive() {
                received.withLock { $0.append(message) }
            }
        }
        defer { collector.cancel() }

        // Sentinel first: once it is yielded, the receive loop has drained the
        // socket, so the next raw send arrives as its own fresh read chunk.
        let sentinel = Data(#"{"sentinel":0}"#.utf8)
        let dropped = Data(#"{"dropped":1}"#.utf8)
        let survivor = Data(#"{"survivor":2}"#.utf8)
        let newline = Data([UInt8(ascii: "\n")])

        try await rawSend(rawPeer, sentinel + newline)
        _ = try await pollUntil(
            { received.withLock { $0.count >= 1 ? $0 : nil } },
            failure: "sentinel message never arrived"
        )

        // The defect: heartbeat and message written as ONE chunk. The receive
        // loop sees the heartbeat magic at the chunk head and discards the
        // whole read, message included. Give the loop time to consume it
        // before the survivor lands, so the two sends cannot coalesce into a
        // single (also fully discarded) read.
        try await rawSend(rawPeer, NetworkTransport.Heartbeat().data + dropped + newline)
        try await Task.sleep(for: .milliseconds(500))
        try await rawSend(rawPeer, survivor + newline)

        let messages = try await pollUntil(
            { received.withLock { $0.contains(survivor) ? $0 : nil } },
            failure: "survivor message never arrived"
        )
        #expect(messages.first == sentinel)
        #expect(!messages.contains(dropped), "expected the coalesced message to be dropped")
        await transport.disconnect()
    }

    private func awaitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    cont.resume()
                    connection.stateUpdateHandler = nil
                case let .failed(error), let .waiting(error):
                    cont.resume(throwing: error)
                    connection.stateUpdateHandler = nil
                case .cancelled:
                    cont.resume(throwing: CancellationError())
                    connection.stateUpdateHandler = nil
                default:
                    break
                }
            }
            connection.start(queue: .global(qos: .userInitiated))
        }
    }

    private func rawSend(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        cont.resume(throwing: error)
                    } else {
                        cont.resume()
                    }
                }
            )
        }
    }
}

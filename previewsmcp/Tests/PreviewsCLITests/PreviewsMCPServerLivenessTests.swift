import Foundation
import MCP
import os
@testable import PreviewsCLI
import Testing

/// The stage-4 dead-client detection: the server pings its client on an
/// interval and disconnects after `missedPongLimit` pings with no inbound
/// traffic of any kind. Any frame counts as life — the characterized SDK
/// client answers server pings with methodNotFound, and that is a live
/// peer.
@Suite("PreviewsMCPServer client liveness")
struct PreviewsMCPServerLivenessTests {
    @Test("a silent client is disconnected after the missed-pong limit")
    func silentClientIsDisconnected() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = PreviewsMCPServer(
            name: "liveness", version: "1",
            liveness: .init(interval: .milliseconds(50), missedPongLimit: 2)
        )
        try await server.start(transport: serverSide)
        try await clientSide.connect()

        let completed = completionFlag(of: server)
        defer { completed.waiter.cancel() }

        try await pollUntil(
            { completed.flag.withLock { $0 } },
            failure: "a silent client was never declared dead"
        )
        await server.stop()
    }

    @Test("a client that answers pings, even with an error, stays connected")
    func respondingClientStaysAlive() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let server = PreviewsMCPServer(
            name: "liveness", version: "1",
            liveness: .init(interval: .milliseconds(50), missedPongLimit: 5)
        )
        try await server.start(transport: serverSide)
        try await clientSide.connect()

        // Mimic the characterized SDK client: no ping handler, so every
        // server ping gets a methodNotFound ERROR response.
        let sawPing = OSAllocatedUnfairLock(initialState: false)
        let responder = FrameCollector(reading: clientSide) { frame in
            guard
                let object = FrameCollector.object(frame),
                object["method"] as? String == "ping",
                let id = object["id"]
            else { return }
            sawPing.withLock { $0 = true }
            let reply: [String: Any] = [
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": -32601, "message": "Method not found"],
            ]
            guard
                let data = try? JSONSerialization.data(withJSONObject: reply, options: [.sortedKeys])
            else { return }
            try? await clientSide.send(data)
        }
        defer { responder.stop() }

        let completed = completionFlag(of: server)
        defer { completed.waiter.cancel() }

        try await pollUntil(
            { sawPing.withLock { $0 } },
            failure: "the server never pinged its client"
        )
        // Ten intervals of answered pings: the connection must survive.
        try await Task.sleep(for: .milliseconds(500))
        #expect(!completed.flag.withLock { $0 }, "a responding client was declared dead")
        await server.stop()
    }

    private func completionFlag(
        of server: PreviewsMCPServer
    ) -> (flag: OSAllocatedUnfairLock<Bool>, waiter: Task<Void, Never>) {
        let flag = OSAllocatedUnfairLock(initialState: false)
        let waiter = Task {
            await server.waitUntilCompleted()
            flag.withLock { $0 = true }
        }
        return (flag, waiter)
    }
}

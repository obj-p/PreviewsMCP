import Foundation
import MCP
import os
@testable import PreviewsCLI
import Testing

/// Characterizes the SDK `Client` behaviors the CLI relies on — the
/// contracts DaemonClient's configure ordering and StallTimer are built on.
/// The rewrite's client must pass this suite unchanged.
@Suite("SDK Client characterization")
struct SDKClientCharacterizationTests {
    @Test("a handler registered before connect receives a notification sent right after initialize")
    func preHandshakeRegistrationReceivesEarlyNotification() async throws {
        let received = OSAllocatedUnfairLock(initialState: false)
        try await Self.withConnectedClient(
            notifyImmediatelyAfterInitialize: true,
            configure: { client in
                // Mirrors DaemonClient's contract: configure registers
                // handlers BEFORE connect so early notifications are never
                // dropped.
                await client.onNotification(LogMessageNotification.self) { _ in
                    received.withLock { $0 = true }
                }
            }
        ) { _, _ in
            try await pollUntil(
                { received.withLock { $0 } },
                failure: "early notification was dropped despite pre-connect registration"
            )
        }
    }

    @Test("disconnect drains a pending callTool with an error instead of hanging")
    func disconnectDrainsPendingCallTool() async throws {
        // The pinned contract is the METHOD-AGNOSTIC pending-request drain:
        // the SDK keeps one request table for every method, so this covers
        // an abandoned ping() (the liveness death path) as much as callTool.
        try await Self.withConnectedClient { client, responder in
            // The responder never answers tools/call, so this call can only
            // end via disconnect's drain — the StallTimer's entire safety
            // contract.
            let pending = Task { try await client.callToolStructured(name: "never-answered") }
            let outcome = OSAllocatedUnfairLock(
                initialState: Result<CallTool.Result, Swift.Error>?.none
            )
            let observer = Task {
                let result = await pending.result
                outcome.withLock { $0 = result }
            }
            defer { observer.cancel() }

            do {
                try await pollUntil(
                    { responder.collector.sawMethod("tools/call") },
                    failure: "tools/call never reached the wire"
                )
            } catch {
                pending.cancel()
                throw error
            }

            await client.disconnect()

            // Bounded: if the drain contract regresses, this polls out red
            // instead of wedging the target on an unresumed continuation.
            let drained = try await pollUntil(
                { outcome.withLock { $0 } },
                failure: "disconnect did not drain the pending callTool"
            )
            guard case .failure = drained else {
                Issue.record("pending callTool returned a value after disconnect")
                return
            }
        }
    }

    // MARK: - Liveness (bidirectional MCP ping)

    @Test("a server-initiated ping is answered with methodNotFound when no handler is registered")
    func serverPingWithoutHandlerGetsMethodNotFound() async throws {
        // The SDK client registers NO default ping handler, so the pong is
        // an ERROR response. The daemon's dead-client detection must accept
        // any response — result or error — as proof of life while SDK
        // clients are on the wire (stage 5-6 window, MCPTestServer forever).
        try await Self.withConnectedClient { _, responder in
            try await responder.send(#"{"id":"srv-ping-1","jsonrpc":"2.0","method":"ping"}"#)
            let reply = try await pollUntil(
                { responder.collector.frame(forID: "srv-ping-1") },
                failure: "client never responded to the server-initiated ping"
            )
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32601, "expected methodNotFound: \(error)")
        }
    }

    @Test("a registered Ping handler answers a server-initiated ping with an empty result")
    func serverPingWithHandlerAnswersCleanly() async throws {
        try await Self.withConnectedClient(
            configure: { client in
                _ = await client.withMethodHandler(Ping.self) { _ in Empty() }
            }
        ) { _, responder in
            try await responder.send(#"{"id":"srv-ping-2","jsonrpc":"2.0","method":"ping"}"#)
            let reply = try await pollUntil(
                { responder.collector.frame(forID: "srv-ping-2") },
                failure: "client never answered the ping despite a registered handler"
            )
            #expect(reply["error"] == nil)
            #expect(reply["result"] != nil)
        }
    }

    @Test("Client.ping() completes against a server that answers ping")
    func clientPingRoundTrip() async throws {
        try await Self.withConnectedClient { client, _ in
            try await Self.expectPingCompletes(client, failure: "ping never completed")
        }
    }

    @Test("a server-initiated ping is answered while the client's own callTool is pending")
    func serverPingAnsweredDuringClientInFlightCall() async throws {
        // The daemon only needs dead-client detection while a long render
        // is in flight — so the pong must not serialize behind the client's
        // pending request.
        try await Self.withConnectedClient { client, responder in
            try await Self.withPendingCallTool(client, responder) {
                try await responder.send(#"{"id":"srv-ping-3","jsonrpc":"2.0","method":"ping"}"#)
                let reply = try await pollUntil(
                    { responder.collector.frame(forID: "srv-ping-3") },
                    failure: "no pong while the client's callTool was pending"
                )
                #expect(reply["method"] == nil, "expected a response frame, got a request: \(reply)")
            }
        }
    }

    @Test("Client.ping() completes while the client's own callTool is pending")
    func clientPingCompletesDuringInFlightCall() async throws {
        // StallTimer's rewrite keys off pong latency measured DURING a
        // render, so the client must multiplex an outstanding ping
        // alongside the pending callTool and correlate both responses.
        try await Self.withConnectedClient { client, responder in
            try await Self.withPendingCallTool(client, responder) {
                try await Self.expectPingCompletes(
                    client, failure: "ping never completed while the callTool was pending"
                )
            }
        }
    }

    /// Holds a callTool pending (the responder never answers tools/call),
    /// confirmed on the wire, for the duration of `body`.
    private static func withPendingCallTool(
        _ client: Client, _ responder: RawResponder,
        _ body: () async throws -> Void
    ) async throws {
        let pending = Task { try await client.callToolStructured(name: "never-answered") }
        defer { pending.cancel() }
        try await pollUntil(
            { responder.collector.sawMethod("tools/call") },
            failure: "tools/call never reached the wire"
        )
        try await body()
    }

    /// Runs `client.ping()` on a child task and polls for the outcome, so a
    /// regression polls out red instead of wedging the suite.
    private static func expectPingCompletes(
        _ client: Client, failure: Comment
    ) async throws {
        let outcome = OSAllocatedUnfairLock(initialState: Result<Void, Swift.Error>?.none)
        let pinging = Task {
            do {
                try await client.ping()
                outcome.withLock { $0 = .success(()) }
            } catch {
                outcome.withLock { $0 = .failure(error) }
            }
        }
        defer { pinging.cancel() }
        let result = try await pollUntil({ outcome.withLock { $0 } }, failure: failure)
        if case let .failure(error) = result {
            Issue.record("ping failed: \(error)")
        }
    }

    /// Scopes a connected client + raw responder so disconnect/stop run on
    /// every path; `configure` runs before connect, like DaemonClient's.
    private static func withConnectedClient(
        notifyImmediatelyAfterInitialize: Bool = false,
        configure: (Client) async -> Void = { _ in },
        _ body: (Client, RawResponder) async throws -> Void
    ) async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(
            on: serverSide, notifyImmediatelyAfterInitialize: notifyImmediatelyAfterInitialize
        )
        defer { responder.stop() }

        let client = Client(name: "probe", version: "1")
        await configure(client)
        _ = try await client.connect(transport: clientSide)
        do {
            try await body(client, responder)
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    /// Plays the server end of the pair in raw JSON-RPC: answers initialize
    /// (echoing the client's id verbatim) and ping; records every frame via
    /// its collector and ignores everything else — tools/call deliberately
    /// never gets an answer, so tests can hold a request pending.
    private struct RawResponder {
        let collector: FrameCollector
        private let transport: InMemoryTransport

        static func start(
            on transport: InMemoryTransport,
            notifyImmediatelyAfterInitialize: Bool = false
        ) async throws -> RawResponder {
            try await transport.connect()
            let collector = FrameCollector(reading: transport) { frame in
                guard
                    let object = FrameCollector.object(frame),
                    let id = object["id"]
                else { return }
                switch object["method"] as? String {
                case "initialize":
                    await respond(on: transport, [
                        "jsonrpc": "2.0",
                        "id": id,
                        "result": [
                            "capabilities": ["logging": [:]],
                            "protocolVersion": Version.latest,
                            "serverInfo": ["name": "raw", "version": "1"],
                        ],
                    ])
                    if notifyImmediatelyAfterInitialize {
                        try? await transport.send(Data(
                            #"{"jsonrpc":"2.0","method":"notifications/message","params":{"data":"early","level":"debug","logger":"probe"}}"#
                                .utf8
                        ))
                    }
                case "ping":
                    await respond(on: transport, ["jsonrpc": "2.0", "id": id, "result": [:]])
                default:
                    break
                }
            }
            return RawResponder(collector: collector, transport: transport)
        }

        func send(_ raw: String) async throws {
            try await transport.send(Data(raw.utf8))
        }

        func stop() {
            collector.stop()
        }

        private static func respond(on transport: InMemoryTransport, _ object: [String: Any]) async {
            guard
                let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
            else { return }
            try? await transport.send(data)
        }
    }
}

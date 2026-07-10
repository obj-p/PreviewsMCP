import Foundation
import MCP
import os
@testable import PreviewsCLI
import Testing

/// Characterizes the client behaviors the CLI relies on — the contracts
/// DaemonClient's configure ordering and stall handling are built on — and
/// runs every seam-expressible pin against BOTH implementations: the SDK
/// `Client` (the original characterization subject) and the in-house
/// `PreviewsMCPClient` (rewrite stage 6). Pins that reach for SDK-only API
/// (`Client.ping()`, `withMethodHandler`) stay SDK-typed; the in-house
/// equivalents are the liveness pins in `PreviewsMCPClientLivenessTests`.
@Suite("MCP client characterization (SDK + in-house)")
struct SDKClientCharacterizationTests {
    enum ClientKind: String, CaseIterable {
        case sdk
        case inHouse
    }

    @Test(
        "connect sends initialize with our identity, then notifications/initialized",
        arguments: ClientKind.allCases
    )
    func handshakeWireShape(kind: ClientKind) async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)
        defer { responder.stop() }

        let client = Self.makeClient(kind)
        let initResult = try await client.connect(transport: clientSide)
        defer { Task { await client.disconnect() } }
        #expect(initResult.protocolVersion == Version.latest)

        try await pollUntil(
            { responder.collector.sawMethod("notifications/initialized") },
            failure: "initialized notification never followed the handshake"
        )
        let initialize = try #require(responder.collector.notification(method: "initialize"))
        let params = try #require(initialize["params"] as? [String: Any])
        #expect(params["protocolVersion"] as? String == Version.latest)
        let info = try #require(params["clientInfo"] as? [String: Any])
        #expect(info["name"] as? String == "probe")
        #expect(info["version"] as? String == "1")
    }

    @Test(
        "a handler registered before connect receives a notification sent right after initialize",
        arguments: ClientKind.allCases
    )
    func preHandshakeRegistrationReceivesEarlyNotification(kind: ClientKind) async throws {
        let received = OSAllocatedUnfairLock(initialState: false)
        try await Self.withConnectedClient(
            kind: kind, notifyImmediatelyAfterInitialize: true
        ) { client in
            // Mirrors DaemonClient's contract: configure registers
            // handlers BEFORE connect so early notifications are never
            // dropped.
            await client.onNotification(LogMessageNotification.self) { _ in
                received.withLock { $0 = true }
            }
        } _: { _, _ in
            try await pollUntil(
                { received.withLock { $0 } },
                failure: "early notification was dropped despite pre-connect registration"
            )
        }
    }

    @Test(
        "disconnect drains a pending callTool with an error instead of hanging",
        arguments: ClientKind.allCases
    )
    func disconnectDrainsPendingCallTool(kind: ClientKind) async throws {
        // The pinned contract is the METHOD-AGNOSTIC pending-request drain —
        // the entire safety contract stall handling is built on.
        try await Self.withConnectedClient(kind: kind) { client, responder in
            // The responder never answers tools/call, so this call can only
            // end via disconnect's drain.
            let call = PendingToolCall(on: client)
            defer { call.cancel() }
            try await pollUntil(
                { responder.collector.sawMethod("tools/call") },
                failure: "tools/call never reached the wire"
            )

            await client.disconnect()
            try await call.expectDrained(failure: "disconnect did not drain the pending callTool")
        }
    }

    // MARK: - Liveness (bidirectional MCP ping)

    @Test(
        "a server-initiated ping gets a response: methodNotFound from the SDK, a real pong in-house",
        arguments: ClientKind.allCases
    )
    func serverPingGetsResponse(kind: ClientKind) async throws {
        // The daemon's dead-client detection accepts ANY response — result
        // or error — as proof of life, so both shapes below keep the
        // connection alive. The SDK client registers no default ping
        // handler (error pong); the in-house client answers properly.
        try await Self.withConnectedClient(kind: kind) { _, responder in
            try await responder.send(#"{"id":"srv-ping-1","jsonrpc":"2.0","method":"ping"}"#)
            let reply = try await pollUntil(
                { responder.collector.frame(forID: "srv-ping-1") },
                failure: "client never responded to the server-initiated ping"
            )
            switch kind {
            case .sdk:
                let error = try #require(reply["error"] as? [String: Any])
                #expect(error["code"] as? Int == -32601, "expected methodNotFound: \(error)")
            case .inHouse:
                #expect(reply["error"] == nil)
                #expect(reply["result"] != nil)
            }
        }
    }

    @Test("a registered Ping handler answers a server-initiated ping with an empty result")
    func serverPingWithHandlerAnswersCleanly() async throws {
        try await Self.withConnectedClient(kind: .sdk) { client in
            let sdk = client as? Client
            _ = await sdk?.withMethodHandler(Ping.self) { _ in Empty() }
        } _: { _, responder in
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
        try await Self.withConnectedClient(kind: .sdk) { client, _ in
            let sdk = try #require(client as? Client)
            try await Self.expectPingCompletes(sdk, failure: "ping never completed")
        }
    }

    @Test(
        "a server-initiated ping is answered while the client's own callTool is pending",
        arguments: ClientKind.allCases
    )
    func serverPingAnsweredDuringClientInFlightCall(kind: ClientKind) async throws {
        // The daemon only needs dead-client detection while a long render
        // is in flight — so the pong must not serialize behind the client's
        // pending request.
        try await Self.withConnectedClient(kind: kind) { client, responder in
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
        // The in-house equivalent — liveness pings multiplexing alongside a
        // pending callTool — is pinned in PreviewsMCPClientLivenessTests.
        try await Self.withConnectedClient(kind: .sdk) { client, responder in
            let sdk = try #require(client as? Client)
            try await Self.withPendingCallTool(client, responder) {
                try await Self.expectPingCompletes(
                    sdk, failure: "ping never completed while the callTool was pending"
                )
            }
        }
    }

    private static func makeClient(_ kind: ClientKind) -> any MCPClienting {
        switch kind {
        case .sdk:
            Client(name: "probe", version: "1")
        case .inHouse:
            PreviewsMCPClient(name: "probe", version: "1")
        }
    }

    /// Holds a callTool pending (the responder never answers tools/call),
    /// confirmed on the wire, for the duration of `body`.
    private static func withPendingCallTool(
        _ client: any MCPClienting, _ responder: RawResponder,
        _ body: () async throws -> Void
    ) async throws {
        let pending = Task { try await client.callToolStructured(name: "never-answered", arguments: nil) }
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
        kind: ClientKind,
        notifyImmediatelyAfterInitialize: Bool = false,
        configure: (any MCPClienting) async -> Void = { _ in },
        _ body: (any MCPClienting, RawResponder) async throws -> Void
    ) async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(
            on: serverSide, notifyImmediatelyAfterInitialize: notifyImmediatelyAfterInitialize
        )
        defer { responder.stop() }

        let client = makeClient(kind)
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
}

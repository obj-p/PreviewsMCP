import Foundation
import MCP
import os
@testable import PreviewsCLI
import Testing

/// The stage-6 pong-fed stall handling: the client pings the daemon on an
/// interval, ANY inbound frame counts as life, and after `missedPongLimit`
/// pings with no traffic the client disconnects — which drains every
/// pending request continuation with an error. These pins replace the
/// notification-fed StallTimer's contract, plus the deliberate divergence
/// from the SDK client: a transport EOF also drains pending requests
/// instead of busy-spinning.
@Suite("PreviewsMCPClient server liveness")
struct PreviewsMCPClientLivenessTests {
    @Test("a silent daemon is declared dead and the pending callTool drains")
    func silentDaemonDisconnectsAndDrains() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        // Answers initialize only: every liveness ping goes unanswered, the
        // exact face of a wedged daemon (process alive, loop parked).
        let responder = try await RawResponder.start(on: serverSide, answersPings: false)
        defer { responder.stop() }

        let client = PreviewsMCPClient(
            name: "probe", version: "1",
            liveness: .init(interval: .milliseconds(50), missedPongLimit: 2)
        )
        _ = try await client.connect(transport: clientSide)

        let call = PendingToolCall(on: client)
        defer { call.cancel() }
        try await call.expectDrained(failure: "liveness never declared the silent daemon dead")

        // The connection is spent: later calls fail fast instead of parking
        // a fresh continuation on a dead wire.
        await #expect(throws: (any Error).self) {
            try await client.callToolStructured(name: "after-death")
        }
        await client.disconnect()
    }

    @Test("a daemon that answers pings keeps the connection and the pending call alive")
    func respondingDaemonStaysAlive() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)
        defer { responder.stop() }

        let client = PreviewsMCPClient(
            name: "probe", version: "1",
            liveness: .init(interval: .milliseconds(50), missedPongLimit: 5)
        )
        _ = try await client.connect(transport: clientSide)

        // A pending render analog: tools/call is never answered, so only
        // ping traffic keeps the connection alive.
        let call = PendingToolCall(on: client)
        defer { call.cancel() }

        // Event-based, not wall-clock: eight answered pings can only happen
        // if the pong reset keeps working past the missed-pong limit;
        // machine load delays the events instead of failing the test.
        try await pollUntil(
            { responder.collector.countMethod("ping") >= 8 },
            failure: "the client stopped pinging a responsive daemon"
        )
        #expect(
            call.currentOutcome() == nil,
            "a responsive daemon's pending call was drained"
        )
        await client.disconnect()
        try await call.expectDrained(failure: "disconnect did not drain the pending callTool")
    }

    @Test("transport EOF drains the pending callTool (the SDK client busy-spins here)")
    func eofDrainsPending() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)

        let client = PreviewsMCPClient(name: "probe", version: "1")
        _ = try await client.connect(transport: clientSide)

        let call = PendingToolCall(on: client)
        defer { call.cancel() }
        try await pollUntil(
            { responder.collector.sawMethod("tools/call") },
            failure: "tools/call never reached the wire"
        )

        // The daemon process dies: its end closes and the client's receive
        // stream finishes. The pending call must drain, not hang.
        responder.stop()
        await responder.disconnect()

        try await call.expectDrained(failure: "EOF did not drain the pending callTool")
        await client.disconnect()
    }
}

import Foundation
import MCP
import os
@testable import PreviewsCLI
import System
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

    @Test("the missed-pong check keeps running while the send chain is wedged")
    func wedgedSendChainStillDisconnects() async throws {
        // The wedge class liveness exists for: the peer keeps the socket
        // open but stops draining, so a large frame parks the transport's
        // send chain in the EAGAIN retry. Pings are fire-and-forget — the
        // loop's timer and missed-pong check must keep running and tear
        // the connection down anyway.
        let pipe = Pipe()
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let transport = FramedTransport(
            input: input,
            output: .init(rawValue: pipe.fileHandleForWriting.fileDescriptor)
        )
        try await transport.connect()

        let wedged = Task {
            try? await transport.send(Data(repeating: UInt8(ascii: "y"), count: 300_000))
        }
        defer { wedged.cancel() }

        let probe = PingProbe()
        let loopEnded = OSAllocatedUnfairLock(initialState: false)
        let pinger = Task {
            await probe.pingLoop(
                on: transport,
                .init(interval: .milliseconds(50), missedPongLimit: 2),
                peer: "peer"
            )
            loopEnded.withLock { $0 = true }
        }
        defer { pinger.cancel() }

        try await pollUntil(
            { loopEnded.withLock { $0 } },
            failure: "a wedged send chain parked the liveness loop"
        )
        withExtendedLifetime(pipe) {}
    }

    @Test("cancelling the task running callToolStructured resumes with CancellationError")
    func cancellationResumesPromptly() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)
        defer { responder.stop() }

        let client = PreviewsMCPClient(name: "probe", version: "1")
        _ = try await client.connect(transport: clientSide)

        let call = PendingToolCall(on: client)
        try await pollUntil(
            { responder.collector.sawMethod("tools/call") },
            failure: "tools/call never reached the wire"
        )

        call.cancel()
        let drained = try await pollUntil(
            { call.currentOutcome() },
            failure: "cancel left the pending callTool parked"
        )
        guard case let .failure(error) = drained else {
            Issue.record("cancelled callTool returned a value")
            return
        }
        #expect(error is CancellationError, "expected CancellationError, got \(error)")
        await client.disconnect()
    }

    @Test("a server-sent notifications/cancelled fails the pending request it names")
    func serverCancelledNotificationDrainsPending() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)
        defer { responder.stop() }

        let client = PreviewsMCPClient(name: "probe", version: "1")
        _ = try await client.connect(transport: clientSide)

        let call = PendingToolCall(on: client)
        defer { call.cancel() }
        try await pollUntil(
            { responder.collector.sawMethod("tools/call") },
            failure: "tools/call never reached the wire"
        )
        let requestID = try #require(
            responder.collector.notification(method: "tools/call")?["id"]
        )

        let idJSON =
            if let text = requestID as? String {
                #""\#(text)""#
            } else {
                "\(requestID)"
            }
        try await responder.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":\#(idJSON)}}"#
        )

        let drained = try await pollUntil(
            { call.currentOutcome() },
            failure: "notifications/cancelled did not fail the pending request"
        )
        guard case .failure = drained else {
            Issue.record("cancelled request returned a value")
            return
        }
        await client.disconnect()
    }

    @Test("failed ping sends still tear the connection down within the limit")
    func failedPingSendsStillDisconnect() async throws {
        // Fire-and-forget pings surface a dead output only as missed
        // pongs: stage 4's immediate honest-close on a failed ping send
        // degrades to <= limit intervals of detection latency. This pins
        // the disconnect through the send-FAILURE path (EBADF on a
        // read-only output; the first failure also poisons the
        // transport, so later pings fail instantly).
        let input = try FileDescriptor.open("/dev/null", .readWrite)
        defer { try? input.close() }
        let output = try FileDescriptor.open("/dev/null", .readOnly)
        defer { try? output.close() }
        let transport = FramedTransport(input: input, output: output)
        try await transport.connect()

        let probe = PingProbe()
        let loopEnded = OSAllocatedUnfairLock(initialState: false)
        let pinger = Task {
            await probe.pingLoop(
                on: transport,
                .init(interval: .milliseconds(50), missedPongLimit: 2),
                peer: "peer"
            )
            loopEnded.withLock { $0 = true }
        }
        defer { pinger.cancel() }

        try await pollUntil(
            { loopEnded.withLock { $0 } },
            failure: "failed ping sends never tore the connection down"
        )
    }

    private actor PingProbe: LivenessPinging {
        var missedPongs = 0
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

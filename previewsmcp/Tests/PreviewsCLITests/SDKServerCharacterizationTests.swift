import Foundation
import MCP
import os
@testable import PreviewsCLI
import Testing

/// Characterizes the server behaviors the daemon relies on, and runs every
/// test against BOTH implementations: the SDK `Server` (the original
/// characterization subject) and the in-house `PreviewsMCPServer` (rewrite
/// stage 4). The assertions are the acceptance bar for the rewrite — they
/// were pinned against the SDK first and must hold unchanged for the
/// replacement. Each test drives a server configured like
/// `configureMCPServer` through the SDK's `InMemoryTransport` pair,
/// speaking raw JSON-RPC frames from the client side.
///
/// Deliberately out of scope: JSON-RPC batch requests. No client of the
/// daemon sends them (Claude Code and the CLI both issue single requests),
/// so the rewrite is not required to support batching; revisit if a batching
/// client ever appears.
@Suite("MCP server characterization (SDK + in-house)")
struct SDKServerCharacterizationTests {
    private static let serverVersion = "0.0.1-characterization"

    enum ServerKind: String, CaseIterable {
        case sdk
        case inHouse
    }

    // MARK: - Version negotiation

    @Test(
        "initialize echoes every supported protocol version",
        arguments: ServerKind.allCases, Version.supported.sorted()
    )
    func initializeEchoesSupportedVersion(kind: ServerKind, version: String) async throws {
        try await Wire.with(kind) { wire in
            let reply = try await wire.roundTrip(id: 1, Self.initialize(version: version))
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == version)
        }
    }

    @Test(
        "initialize falls back to the latest version and advertises the server's own version",
        arguments: ServerKind.allCases
    )
    func initializeFallsBackToLatest(kind: ServerKind) async throws {
        try await Wire.with(kind) { wire in
            let reply = try await wire.roundTrip(id: 1, Self.initialize(version: "1999-01-01"))
            let result = try #require(reply["result"] as? [String: Any])
            #expect(result["protocolVersion"] as? String == Version.latest)

            // DaemonClient's version-mismatch respawn keys off this field.
            let serverInfo = try #require(result["serverInfo"] as? [String: Any])
            #expect(serverInfo["version"] as? String == Self.serverVersion)
        }
    }

    // MARK: - Wire shape

    @Test(
        "responses encode with sorted keys and unescaped slashes",
        arguments: ServerKind.allCases
    )
    func responseWireShape(kind: ServerKind) async throws {
        try await Wire.with(kind) { server in
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: [
                    Tool(
                        name: "probe",
                        description: "renders previews/for-tests",
                        inputSchema: .object(["type": .string("object")])
                    ),
                ])
            }
        } _: { wire in
            try await wire.handshake()
            _ = try await wire.roundTrip(id: 2, #"{"id":2,"jsonrpc":"2.0","method":"tools/list"}"#)

            let raw = try #require(wire.collector.rawFrame(forID: 2))
            let text = String(decoding: raw, as: UTF8.self)
            #expect(!text.contains(#"\/"#), "slashes must not be escaped: \(text)")
            let idIndex = try #require(text.range(of: #""id""#)?.lowerBound)
            let jsonrpcIndex = try #require(text.range(of: #""jsonrpc""#)?.lowerBound)
            let resultIndex = try #require(text.range(of: #""result""#)?.lowerBound)
            #expect(
                idIndex < jsonrpcIndex && jsonrpcIndex < resultIndex,
                "keys must be sorted: \(text)"
            )
        }
    }

    // MARK: - Request handling contracts

    @Test(
        "an unknown request method gets a methodNotFound error, not silence",
        arguments: ServerKind.allCases
    )
    func unknownMethodGetsError(kind: ServerKind) async throws {
        // The daemon registers no logging/setLevel handler; an unknown
        // method must error back, never go silent — a client awaiting a
        // response to an unhandled method would hang until liveness
        // tears the connection down.
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            let reply = try await wire.roundTrip(
                id: 9,
                #"{"id":9,"jsonrpc":"2.0","method":"logging/setLevel","params":{"level":"debug"}}"#
            )
            let error = try #require(reply["error"] as? [String: Any])
            #expect(error["code"] as? Int == -32601, "expected methodNotFound: \(error)")
        }
    }

    @Test("ping answers with an empty result", arguments: ServerKind.allCases)
    func pingAnswers(kind: ServerKind) async throws {
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            let reply = try await wire.roundTrip(id: 4, #"{"id":4,"jsonrpc":"2.0","method":"ping"}"#)
            #expect(reply["error"] == nil)
            #expect(reply["result"] != nil)
        }
    }

    @Test(
        "ping is answered while a CallTool handler is still in flight",
        arguments: ServerKind.allCases
    )
    func pingAnsweredDuringInFlightCall(kind: ServerKind) async throws {
        // Client liveness is pong-fed, so a pong must not queue behind a
        // long render.
        let started = OSAllocatedUnfairLock(initialState: false)
        let release = OSAllocatedUnfairLock(initialState: false)
        try await Wire.with(kind) { server in
            await server.withMethodHandler(CallTool.self) { _ in
                started.withLock { $0 = true }
                while !release.withLock({ $0 }) {
                    try await Task.sleep(for: .milliseconds(10))
                }
                return CallTool.Result(content: [.text("done")])
            }
        } _: { wire in
            defer { release.withLock { $0 = true } }
            try await wire.handshake()
            try await wire.send(
                #"{"id":21,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{},"name":"slow"}}"#
            )
            // The premise: the handler must be RUNNING when the ping goes
            // out, or a server that answers pings before dispatching queued
            // calls would pass vacuously.
            try await pollUntil(
                { started.withLock { $0 } },
                failure: "the CallTool handler never started"
            )
            let pong = try await wire.roundTrip(id: 22, #"{"id":22,"jsonrpc":"2.0","method":"ping"}"#)
            #expect(pong["error"] == nil)
            #expect(pong["result"] != nil)
            #expect(
                wire.collector.frame(forID: 21) == nil,
                "the slow call must still be pending when the pong arrives"
            )
            release.withLock { $0 = true }
            _ = try await pollUntil(
                { wire.collector.frame(forID: 21) },
                failure: "the released CallTool never completed"
            )
        }
    }

    @Test(
        "a malformed frame gets an error response echoing a recoverable id",
        arguments: ServerKind.allCases
    )
    func malformedFrameEchoesIDInError(kind: ServerKind) async throws {
        // Neither server may go silent on a frame that fails to decode: a
        // client awaiting that id would hang forever. The error code is not
        // pinned (the SDK says internalError, the in-house loop parseError);
        // the pinned contract is an ERROR response carrying the sender's id.
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            try await wire.send(#"{"id":77,"jsonrpc":"1.0","method":"ping"}"#)
            let reply = try await pollUntil(
                { wire.collector.frame(forID: 77) },
                failure: "no reply for the malformed frame"
            )
            #expect(reply["error"] != nil, "expected an error response: \(reply)")
        }
    }

    @Test(
        "a frame with both method and result keys is consumed as a response, not dispatched",
        arguments: ServerKind.allCases
    )
    func methodEchoingResponseIsNotDispatched(kind: ServerKind) async throws {
        // Some peers echo the method name in response frames. Classifying
        // request-first would dispatch such a pong as a fresh request and
        // answer it — a spurious frame in the client's id space. The later
        // id-992 round trip orders the assertion: the stream is processed
        // in order, so by the time 992 is answered, 991 was classified.
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            try await wire.send(#"{"id":991,"jsonrpc":"2.0","method":"ping","result":{}}"#)
            let after = try await wire.roundTrip(id: 992, #"{"id":992,"jsonrpc":"2.0","method":"ping"}"#)
            #expect(after["error"] == nil)
            #expect(
                wire.collector.frame(forID: 991) == nil,
                "a response-shaped frame must be consumed, not answered"
            )
        }
    }

    @Test(
        "a response whose result is JSON null is consumed, not answered",
        arguments: ServerKind.allCases
    )
    func nullResultResponseIsConsumed(kind: ServerKind) async throws {
        // "result": null is legal JSON-RPC 2.0. Key PRESENCE, not value,
        // is the response signal — treating null as key-absent would
        // misclassify the frame and answer it with a spurious parse error.
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            try await wire.send(#"{"id":881,"jsonrpc":"2.0","result":null}"#)
            let after = try await wire.roundTrip(id: 882, #"{"id":882,"jsonrpc":"2.0","method":"ping"}"#)
            #expect(after["error"] == nil)
            #expect(
                wire.collector.frame(forID: 881) == nil,
                "a null-result response must be consumed, not answered"
            )
        }
    }

    @Test("an id-only malformed frame gets a parse error echoing that id")
    func idOnlyFrameEchoesIDInParseError() async throws {
        // {"id":N} with no method/result/error cannot be classified; the
        // parse-error reply must still echo the recoverable id so the
        // peer's pending request fails immediately instead of hanging.
        // Pinned in-house only: the frame reaches production servers via
        // buggy encoders, and the SDK's behavior here is not part of the
        // acceptance bar.
        try await Wire.with(.inHouse) { wire in
            try await wire.handshake()
            try await wire.send(#"{"id":55,"jsonrpc":"2.0"}"#)
            let reply = try await pollUntil(
                { wire.collector.frame(forID: 55) },
                failure: "no reply for the id-only malformed frame"
            )
            #expect(reply["error"] != nil, "expected an error response: \(reply)")
        }
    }

    @Test("string request ids are echoed verbatim", arguments: ServerKind.allCases)
    func stringIDRoundTrip(kind: ServerKind) async throws {
        // The SDK Client (the daemon's actual peer) generates random STRING
        // ids; the integer ids used elsewhere in this suite are the less
        // common case.
        try await Wire.with(kind) { wire in
            try await wire.handshake()
            try await wire.send(#"{"id":"req-abc","jsonrpc":"2.0","method":"ping"}"#)
            let reply = try await pollUntil(
                { wire.collector.frame(forID: "req-abc") },
                failure: "no response for string id"
            )
            #expect(reply["id"] as? String == "req-abc")
        }
    }

    // MARK: - Cancellation

    @Test(
        "notifications/cancelled cancels the in-flight CallTool handler",
        arguments: ServerKind.allCases
    )
    func cancelledNotificationCancelsHandler(kind: ServerKind) async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        try await Wire.with(kind) { server in
            await server.withMethodHandler(CallTool.self) { _ in
                started.withLock { $0 = true }
                do {
                    try await Task.sleep(for: .seconds(30))
                } catch {
                    cancelled.withLock { $0 = true }
                    throw error
                }
                return CallTool.Result(content: [.text("finished")])
            }
        } _: { wire in
            try await wire.handshake()

            // String id: cancellation from the daemon's real client
            // (Claude Code / SDK Client) arrives with a string requestId.
            try await wire.send(
                #"{"id":"call-7","jsonrpc":"2.0","method":"tools/call","params":{"arguments":{},"name":"probe"}}"#
            )
            try await pollUntil(
                { started.withLock { $0 } },
                failure: "CallTool handler never started"
            )
            try await wire.send(
                #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":"call-7"}}"#
            )
            try await pollUntil(
                { cancelled.withLock { $0 } },
                failure: "handler was not cancelled by notifications/cancelled"
            )

            // The SDK deterministically sends NOTHING when the handler
            // rethrows CancellationError; an error response appears only if
            // a handler maps cancellation to another error. Both faces occur
            // on the real daemon, so the pinned contract is the disjunction:
            // anything but a successful result.
            try await Task.sleep(for: .milliseconds(200))
            if let reply = wire.collector.frame(forID: "call-7") {
                #expect(reply["result"] == nil, "cancelled request produced a result: \(reply)")
            }

            // The server must keep serving after a cancellation: the id is
            // freed and the next request gets answered.
            let after = try await wire.roundTrip(
                id: 8, #"{"id":8,"jsonrpc":"2.0","method":"ping"}"#
            )
            #expect(after["error"] == nil)
        }
    }

    // MARK: - Notifications

    @Test(
        "server.log reaches the wire as notifications/message",
        arguments: ServerKind.allCases
    )
    func serverLogNotificationReachesWire(kind: ServerKind) async throws {
        try await Wire.with(kind) { wire in
            try await wire.handshake()

            try await wire.server.log(level: .debug, logger: "heartbeat", data: .string("alive"))

            let frame = try await pollUntil(
                { wire.collector.notification(method: "notifications/message") },
                failure: "log notification never reached the wire"
            )
            let params = try #require(frame["params"] as? [String: Any])
            #expect(params["logger"] as? String == "heartbeat")
        }
    }

    @Test(
        "progress tokens decode from _meta and notify as notifications/progress",
        arguments: ServerKind.allCases
    )
    func progressTokenPlumbing(kind: ServerKind) async throws {
        // MCPProgressReporter depends on both halves: CallTool.Parameters
        // exposing _meta.progressToken, and server.notify(ProgressNotification)
        // reaching the wire tagged with that token.
        let token = OSAllocatedUnfairLock(initialState: String?.none)
        try await Wire.with(kind) { server in
            await server.withMethodHandler(CallTool.self) { params in
                if case let .string(value) = params._meta?.progressToken {
                    token.withLock { $0 = value }
                }
                return CallTool.Result(content: [.text("ok")])
            }
        } _: { wire in
            try await wire.handshake()
            _ = try await wire.roundTrip(
                id: 3,
                #"{"id":3,"jsonrpc":"2.0","method":"tools/call","params":{"_meta":{"progressToken":"tok-1"},"arguments":{},"name":"probe"}}"#
            )
            #expect(token.withLock { $0 } == "tok-1")

            try await wire.server.notify(
                ProgressNotification.message(
                    .init(progressToken: .string("tok-1"), progress: 1, total: 2, message: "step")
                )
            )
            let frame = try await pollUntil(
                { wire.collector.notification(method: "notifications/progress") },
                failure: "progress notification never reached the wire"
            )
            let params = try #require(frame["params"] as? [String: Any])
            #expect(params["progressToken"] as? String == "tok-1")
            #expect(params["progress"] as? Double == 1)
        }
    }

    // MARK: - Lifecycle

    @Test(
        "waitUntilCompleted returns when the transport closes",
        arguments: ServerKind.allCases
    )
    func waitUntilCompletedReturnsOnTransportClose(kind: ServerKind) async throws {
        // runMCPServer's entire per-connection teardown: start returns once
        // the receive loop is spawned, and waitUntilCompleted returns when
        // the peer goes away.
        try await Wire.with(kind) { wire in
            let completed = OSAllocatedUnfairLock(initialState: false)
            let waiter = Task {
                await wire.server.waitUntilCompleted()
                completed.withLock { $0 = true }
            }
            await wire.disconnectPeer()
            try await pollUntil(
                { completed.withLock { $0 } },
                failure: "waitUntilCompleted never returned after transport close"
            )
            waiter.cancel()
        }
    }

    // MARK: - Harness

    private static func initialize(version: String) -> String {
        #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"probe","version":"1"},"protocolVersion":"\#(version)"}}"#
    }

    /// A started server (SDK or in-house, per `kind`) plus the raw client
    /// side of its transport. `with` scopes the harness so teardown runs on
    /// every path, including thrown polls.
    struct Wire {
        let server: any MCPServing
        let collector: FrameCollector
        private let testSide: InMemoryTransport

        static func with(
            _ kind: ServerKind,
            _ configure: (any MCPServing) async -> Void = { _ in },
            _ body: (Wire) async throws -> Void
        ) async throws {
            let (testSide, serverSide) = await InMemoryTransport.createConnectedPair()
            let capabilities = Server.Capabilities(
                logging: .init(), tools: .init(listChanged: false)
            )
            let server: any MCPServing =
                switch kind {
                case .sdk:
                    Server(
                        name: "characterization", version: serverVersion,
                        capabilities: capabilities
                    )
                case .inHouse:
                    PreviewsMCPServer(
                        name: "characterization", version: serverVersion,
                        capabilities: capabilities
                    )
                }
            await configure(server)
            try await server.start(transport: serverSide)
            try await testSide.connect()
            let wire = Wire(
                server: server,
                collector: FrameCollector(reading: testSide),
                testSide: testSide
            )
            do {
                try await body(wire)
            } catch {
                await wire.close()
                throw error
            }
            await wire.close()
        }

        func send(_ raw: String) async throws {
            try await testSide.send(Data(raw.utf8))
        }

        /// Close the client side, as a departing peer would.
        func disconnectPeer() async {
            await testSide.disconnect()
        }

        /// Send a request frame and poll for the matching response.
        func roundTrip(id: Int, _ raw: String) async throws -> [String: Any] {
            try await send(raw)
            return try await pollUntil(
                { collector.frame(forID: id) },
                failure: "no response for id \(id)"
            )
        }

        /// initialize + notifications/initialized, the client handshake every
        /// request-bearing test needs first.
        func handshake() async throws {
            _ = try await roundTrip(
                id: 1, SDKServerCharacterizationTests.initialize(version: Version.latest)
            )
            try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        }

        private func close() async {
            collector.stop()
            await server.stop()
        }
    }
}

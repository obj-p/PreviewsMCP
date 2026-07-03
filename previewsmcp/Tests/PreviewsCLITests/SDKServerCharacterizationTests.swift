import Foundation
import MCP
import os
import Testing

/// Characterizes the SDK `Server` behaviors the daemon relies on. This suite
/// is the acceptance bar for the in-house wire-layer rewrite: every test here
/// must pass unchanged against the replacement server loop. Each test drives
/// a server configured like `configureMCPServer` through `InMemoryTransport`,
/// speaking raw JSON-RPC frames from the client side.
@Suite("SDK Server characterization")
struct SDKServerCharacterizationTests {
    // MARK: - Version negotiation

    @Test("initialize echoes every supported protocol version", arguments: Version.supported.sorted())
    func initializeEchoesSupportedVersion(version: String) async throws {
        let wire = try await Wire.start()
        let reply = try await wire.roundTrip(id: 1, Self.initialize(version: version))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == version)
        await wire.close()
    }

    @Test("initialize falls back to the latest version for an unknown one")
    func initializeFallsBackToLatest() async throws {
        let wire = try await Wire.start()
        let reply = try await wire.roundTrip(id: 1, Self.initialize(version: "1999-01-01"))
        let result = try #require(reply["result"] as? [String: Any])
        #expect(result["protocolVersion"] as? String == Version.latest)
        await wire.close()
    }

    // MARK: - Wire shape

    @Test("responses encode with sorted keys and unescaped slashes")
    func responseWireShape() async throws {
        let wire = try await Wire.start { server in
            await server.withMethodHandler(ListTools.self) { _ in
                ListTools.Result(tools: [
                    Tool(
                        name: "probe",
                        description: "renders previews/for-tests",
                        inputSchema: .object(["type": .string("object")])
                    ),
                ])
            }
        }
        try await wire.handshake()
        _ = try await wire.roundTrip(id: 2, #"{"id":2,"jsonrpc":"2.0","method":"tools/list"}"#)

        let raw = try #require(wire.rawFrame(forID: 2))
        let text = String(decoding: raw, as: UTF8.self)
        #expect(!text.contains(#"\/"#), "slashes must not be escaped: \(text)")
        let idIndex = try #require(text.range(of: #""id""#)?.lowerBound)
        let jsonrpcIndex = try #require(text.range(of: #""jsonrpc""#)?.lowerBound)
        let resultIndex = try #require(text.range(of: #""result""#)?.lowerBound)
        #expect(idIndex < jsonrpcIndex && jsonrpcIndex < resultIndex, "keys must be sorted: \(text)")
        await wire.close()
    }

    // MARK: - Cancellation

    @Test("notifications/cancelled cancels the in-flight CallTool handler")
    func cancelledNotificationCancelsHandler() async throws {
        let started = OSAllocatedUnfairLock(initialState: false)
        let cancelled = OSAllocatedUnfairLock(initialState: false)
        let wire = try await Wire.start { server in
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
        }
        try await wire.handshake()

        try await wire.send(
            #"{"id":7,"jsonrpc":"2.0","method":"tools/call","params":{"arguments":{},"name":"probe"}}"#
        )
        _ = try await pollUntil(
            { started.withLock { $0 } ? true : nil },
            failure: "CallTool handler never started"
        )
        try await wire.send(
            #"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":7}}"#
        )
        _ = try await pollUntil(
            { cancelled.withLock { $0 } ? true : nil },
            failure: "handler was not cancelled by notifications/cancelled"
        )

        // A cancelled request must never produce a successful result. (The
        // SDK may send an error response or nothing; both are acceptable to
        // the daemon's clients — a result would not be.)
        try await Task.sleep(for: .milliseconds(200))
        if let reply = wire.frame(forID: 7) {
            #expect(reply["result"] == nil, "cancelled request produced a result: \(reply)")
        }
        await wire.close()
    }

    // MARK: - Notifications

    @Test("server.log reaches the wire as notifications/message")
    func serverLogNotificationReachesWire() async throws {
        let wire = try await Wire.start()
        try await wire.handshake()

        try await wire.server.log(level: .debug, logger: "heartbeat", data: .string("alive"))

        let frame = try await pollUntil(
            { wire.notification(method: "notifications/message") },
            failure: "log notification never reached the wire"
        )
        let params = try #require(frame["params"] as? [String: Any])
        #expect(params["logger"] as? String == "heartbeat")
        await wire.close()
    }

    // MARK: - Harness

    private static func initialize(version: String) -> String {
        #"{"id":1,"jsonrpc":"2.0","method":"initialize","params":{"capabilities":{},"clientInfo":{"name":"probe","version":"1"},"protocolVersion":"\#(version)"}}"#
    }

    /// A started SDK server plus the raw client side of its transport.
    struct Wire {
        let server: Server
        let testSide: InMemoryTransport
        private let frames: OSAllocatedUnfairLock<[Data]>
        private let collector: Task<Void, Never>

        static func start(
            configure: (Server) async -> Void = { _ in }
        ) async throws -> Wire {
            let (serverSide, testSide) = await InMemoryTransport.pair()
            let server = Server(
                name: "characterization",
                version: "0.0.1",
                capabilities: .init(logging: .init(), tools: .init(listChanged: false))
            )
            await configure(server)
            try await server.start(transport: serverSide)

            let frames = OSAllocatedUnfairLock(initialState: [Data]())
            let collector = Task {
                do {
                    for try await frame in await testSide.receive() {
                        frames.withLock { $0.append(frame) }
                    }
                } catch {}
            }
            return Wire(server: server, testSide: testSide, frames: frames, collector: collector)
        }

        func send(_ raw: String) async throws {
            try await testSide.send(Data(raw.utf8))
        }

        /// Send a request frame and poll for the matching response.
        func roundTrip(id: Int, _ raw: String) async throws -> [String: Any] {
            try await send(raw)
            return try await pollUntil(
                { frame(forID: id) },
                failure: "no response for id \(id)"
            )
        }

        /// initialize + notifications/initialized, the client handshake every
        /// request-bearing test needs first.
        func handshake() async throws {
            _ = try await roundTrip(id: 1, SDKServerCharacterizationTests.initialize(version: Version.latest))
            try await send(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#)
        }

        func frame(forID id: Int) -> [String: Any]? {
            rawFrame(forID: id).flatMap(Self.object)
        }

        func rawFrame(forID id: Int) -> Data? {
            frames.withLock { $0 }.first { Self.object($0)?["id"] as? Int == id }
        }

        func notification(method: String) -> [String: Any]? {
            frames.withLock { $0 }.compactMap(Self.object).first { $0["method"] as? String == method }
        }

        func close() async {
            collector.cancel()
            await server.stop()
            await testSide.disconnect()
        }

        private static func object(_ data: Data) -> [String: Any]? {
            (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }
    }
}

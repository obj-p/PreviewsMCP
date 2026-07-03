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
        let (serverSide, clientSide) = await InMemoryTransport.pair()
        let responder = try await RawResponder.start(
            on: serverSide, notifyImmediatelyAfterInitialize: true
        )

        let client = Client(name: "probe", version: "1")
        let received = OSAllocatedUnfairLock(initialState: false)
        // Mirrors DaemonClient's contract: configure registers handlers
        // BEFORE connect so early notifications are never dropped.
        await client.onNotification(LogMessageNotification.self) { _ in
            received.withLock { $0 = true }
        }
        _ = try await client.connect(transport: clientSide)

        _ = try await pollUntil(
            { received.withLock { $0 } ? true : nil },
            failure: "early notification was dropped despite pre-connect registration"
        )
        await client.disconnect()
        responder.stop()
    }

    @Test("disconnect drains a pending callTool with an error instead of hanging")
    func disconnectDrainsPendingCallTool() async throws {
        let (serverSide, clientSide) = await InMemoryTransport.pair()
        let responder = try await RawResponder.start(on: serverSide)

        let client = Client(name: "probe", version: "1")
        _ = try await client.connect(transport: clientSide)

        // The responder never answers tools/call, so this call can only end
        // via disconnect's drain — the StallTimer's entire safety contract.
        let pending = Task { try await client.callToolStructured(name: "never-answered") }
        _ = try await pollUntil(
            { responder.sawMethod("tools/call") ? true : nil },
            failure: "tools/call never reached the wire"
        )

        await client.disconnect()

        let outcome = await pending.result
        guard case .failure = outcome else {
            Issue.record("pending callTool returned a value after disconnect")
            responder.stop()
            return
        }
        responder.stop()
    }

    /// Plays the server end of the pair in raw JSON-RPC: answers initialize
    /// (echoing the client's id verbatim), records every method seen, and
    /// ignores everything else.
    private struct RawResponder {
        private let methods: OSAllocatedUnfairLock<[String]>
        private let reader: Task<Void, Never>

        static func start(
            on transport: InMemoryTransport,
            notifyImmediatelyAfterInitialize: Bool = false
        ) async throws -> RawResponder {
            let methods = OSAllocatedUnfairLock(initialState: [String]())
            let reader = Task {
                do {
                    for try await frame in await transport.receive() {
                        let parsed = try? JSONSerialization.jsonObject(with: frame)
                        guard
                            let object = parsed as? [String: Any],
                            let method = object["method"] as? String
                        else { continue }
                        methods.withLock { $0.append(method) }

                        if method == "initialize", let id = object["id"] {
                            let response: [String: Any] = [
                                "jsonrpc": "2.0",
                                "id": id,
                                "result": [
                                    "capabilities": ["logging": [:]],
                                    "protocolVersion": Version.latest,
                                    "serverInfo": ["name": "raw", "version": "1"],
                                ],
                            ]
                            try await transport.send(
                                JSONSerialization.data(withJSONObject: response, options: [.sortedKeys])
                            )
                            if notifyImmediatelyAfterInitialize {
                                try await transport.send(Data(
                                    #"{"jsonrpc":"2.0","method":"notifications/message","params":{"data":"early","level":"debug","logger":"probe"}}"#
                                        .utf8
                                ))
                            }
                        }
                    }
                } catch {}
            }
            return RawResponder(methods: methods, reader: reader)
        }

        func sawMethod(_ method: String) -> Bool {
            methods.withLock { $0 }.contains(method)
        }

        func stop() {
            reader.cancel()
        }
    }
}

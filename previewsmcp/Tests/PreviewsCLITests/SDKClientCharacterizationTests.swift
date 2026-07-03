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
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(
            on: serverSide, notifyImmediatelyAfterInitialize: true
        )
        defer { responder.stop() }

        let client = Client(name: "probe", version: "1")
        let received = OSAllocatedUnfairLock(initialState: false)
        // Mirrors DaemonClient's contract: configure registers handlers
        // BEFORE connect so early notifications are never dropped.
        await client.onNotification(LogMessageNotification.self) { _ in
            received.withLock { $0 = true }
        }
        _ = try await client.connect(transport: clientSide)

        do {
            try await pollUntil(
                { received.withLock { $0 } },
                failure: "early notification was dropped despite pre-connect registration"
            )
        } catch {
            await client.disconnect()
            throw error
        }
        await client.disconnect()
    }

    @Test("disconnect drains a pending callTool with an error instead of hanging")
    func disconnectDrainsPendingCallTool() async throws {
        let (clientSide, serverSide) = await InMemoryTransport.createConnectedPair()
        let responder = try await RawResponder.start(on: serverSide)
        defer { responder.stop() }

        let client = Client(name: "probe", version: "1")
        _ = try await client.connect(transport: clientSide)

        // The responder never answers tools/call, so this call can only end
        // via disconnect's drain — the StallTimer's entire safety contract.
        let pending = Task { try await client.callToolStructured(name: "never-answered") }
        do {
            try await pollUntil(
                { responder.collector.sawMethod("tools/call") },
                failure: "tools/call never reached the wire"
            )
        } catch {
            pending.cancel()
            await client.disconnect()
            throw error
        }

        await client.disconnect()

        let outcome = await pending.result
        guard case .failure = outcome else {
            Issue.record("pending callTool returned a value after disconnect")
            return
        }
    }

    /// Plays the server end of the pair in raw JSON-RPC: answers initialize
    /// (echoing the client's id verbatim), records every frame via its
    /// collector, and ignores everything else.
    private struct RawResponder {
        let collector: FrameCollector

        static func start(
            on transport: InMemoryTransport,
            notifyImmediatelyAfterInitialize: Bool = false
        ) async throws -> RawResponder {
            try await transport.connect()
            let collector = FrameCollector(reading: transport) { frame in
                guard
                    let object = FrameCollector.object(frame),
                    object["method"] as? String == "initialize",
                    let id = object["id"]
                else { return }
                let response: [String: Any] = [
                    "jsonrpc": "2.0",
                    "id": id,
                    "result": [
                        "capabilities": ["logging": [:]],
                        "protocolVersion": Version.latest,
                        "serverInfo": ["name": "raw", "version": "1"],
                    ],
                ]
                guard
                    let data = try? JSONSerialization.data(
                        withJSONObject: response, options: [.sortedKeys]
                    )
                else { return }
                try? await transport.send(data)
                if notifyImmediatelyAfterInitialize {
                    try? await transport.send(Data(
                        #"{"jsonrpc":"2.0","method":"notifications/message","params":{"data":"early","level":"debug","logger":"probe"}}"#
                            .utf8
                    ))
                }
            }
            return RawResponder(collector: collector)
        }

        func stop() {
            collector.stop()
        }
    }
}

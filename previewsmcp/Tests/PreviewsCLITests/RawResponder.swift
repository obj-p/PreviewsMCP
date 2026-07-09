import Foundation
import MCP

/// Plays the server end of an `InMemoryTransport` pair in raw JSON-RPC:
/// answers initialize (echoing the client's id verbatim) and — unless
/// `answersPings` is false — ping; records every inbound frame via its
/// collector and ignores everything else. tools/call deliberately never
/// gets an answer, so tests can hold a request pending. Shared by the
/// client characterization and client liveness suites.
struct RawResponder {
    let collector: FrameCollector
    private let transport: InMemoryTransport

    static func start(
        on transport: InMemoryTransport,
        notifyImmediatelyAfterInitialize: Bool = false,
        answersPings: Bool = true
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
            case "ping" where answersPings:
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

    /// Close the server end mid-session; the client's receive stream
    /// finishes throwing (`InMemoryTransport` peers see connectionClosed).
    func disconnect() async {
        await transport.disconnect()
    }

    private static func respond(on transport: InMemoryTransport, _ object: [String: Any]) async {
        guard
            let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        else { return }
        try? await transport.send(data)
    }
}

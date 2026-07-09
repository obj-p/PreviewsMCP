import Foundation
import MCP
import PreviewsCore

/// In-house MCP server loop (rewrite stage 4). Replaces the SDK `Server` at
/// the stage-5 cutover; the SDK's data types (Method/Request/Response/Value)
/// are kept. The stage-1 characterization suite runs against both servers,
/// so every pinned behavior — version negotiation, methodNotFound, ping,
/// id echo, cancellation, progress, wire shape, teardown — is enforced
/// differentially.
///
/// Concurrency model, load-bearing: each REQUEST runs in its own task so a
/// ping is answered while a render is in flight; NOTIFICATIONS are handled
/// inline in the receive loop so notifications/cancelled can reach a
/// running handler. A handler that throws CancellationError produces NO
/// response frame (MCP spec); other errors produce an error response.
///
/// Liveness (the owner's rewrite requirement): with a `ClientLiveness`
/// config the server pings its client on an interval and disconnects the
/// transport after `missedPongLimit` pings with no response of any kind.
/// Any inbound response counts as proof of life — an SDK client answers
/// server pings with methodNotFound (characterized), and that is a live
/// peer.
actor PreviewsMCPServer: MCPServing {
    struct ClientLiveness {
        var interval: Duration = .seconds(15)
        var missedPongLimit: Int = 2
    }

    /// Type-erased shapes for the first decode pass (the SDK's own AnyMethod
    /// and AnyNotification are internal). Payload fields decode as `Ignored`,
    /// which accepts any shape while reading nothing — classification must
    /// not build a throwaway tree from a several-hundred-KB params blob the
    /// typed handler decodes again. The decoder does not validate the method
    /// name against `name`.
    private struct Ignored: NotRequired, Hashable, Codable {
        init() {}
        init(from _: Decoder) throws {}
    }

    private struct ErasedMethod: MCP.Method {
        static let name = ""
        typealias Parameters = Ignored
        typealias Result = Ignored
    }

    private struct ErasedNotification: MCP.Notification {
        static let name = ""
        typealias Parameters = Ignored
    }

    private let serverInfo: Server.Info
    private let capabilities: Server.Capabilities
    private let liveness: ClientLiveness?
    private var methodHandlers: [String: @Sendable (Data) async throws -> Data] = [:]
    private var transport: (any Transport)?
    private var receiveLoop: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var inFlightRequests: [ID: Task<Data, Swift.Error>] = [:]
    private var isInitialized = false
    private var missedPongs = 0

    init(
        name: String, version: String,
        capabilities: Server.Capabilities = .init(),
        liveness: ClientLiveness? = nil
    ) {
        serverInfo = Server.Info(name: name, version: version)
        self.capabilities = capabilities
        self.liveness = liveness
    }

    @discardableResult
    func withMethodHandler<M: MCP.Method>(
        _: M.Type,
        handler: @escaping @Sendable (M.Parameters) async throws -> M.Result
    ) -> Self {
        methodHandlers[M.name] = { raw in
            let request = try Self.wireDecoder.decode(Request<M>.self, from: raw)
            let result = try await handler(request.params)
            return try Self.encode(M.response(id: request.id, result: result))
        }
        return self
    }

    func start(transport: any Transport) async throws {
        self.transport = transport
        try await transport.connect()
        receiveLoop = Task { await run(on: transport) }
        if let liveness {
            pinger = Task { await pingLoop(on: transport, liveness) }
        }
    }

    func stop() async {
        cancelInFlight()
        pinger?.cancel()
        pinger = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        await transport?.disconnect()
        transport = nil
    }

    func waitUntilCompleted() async {
        await receiveLoop?.value
    }

    func notify(_ notification: Message<some MCP.Notification>) async throws {
        guard let transport else {
            throw MCPError.internalError("Server connection not initialized")
        }
        try await transport.send(try Self.encode(notification))
    }

    func log(level: LogLevel, logger: String? = nil, data: Value) async throws {
        try await notify(LogMessageNotification.message(.init(level: level, logger: logger, data: data)))
    }

    // MARK: - Receive loop

    private func run(on transport: any Transport) async {
        do {
            for try await raw in await transport.receive() {
                // The receive loop is the liveness ground truth: ANY inbound
                // frame proves the peer's process is alive and writing.
                missedPongs = 0
                if let request = try? Self.wireDecoder.decode(Request<ErasedMethod>.self, from: raw) {
                    dispatch(request, raw: raw, on: transport)
                } else if (try? Self.wireDecoder.decode(Response<ErasedMethod>.self, from: raw)) != nil {
                    // A pong (or a stray response); counted above.
                } else if let note = try? Self.wireDecoder.decode(
                    Message<ErasedNotification>.self, from: raw
                ) {
                    handleNotification(note, raw: raw)
                } else {
                    await send(Self.parseErrorResponse(for: raw), on: transport)
                }
            }
        } catch {
            // A stream error ends the connection; teardown is the owner's.
        }
        // The connection is gone: a dead client's in-flight renders must not
        // keep burning compiler/simulator resources.
        cancelInFlight()
        pinger?.cancel()
    }

    private func cancelInFlight() {
        for task in inFlightRequests.values {
            task.cancel()
        }
        inFlightRequests.removeAll()
    }

    private func dispatch(_ request: Request<ErasedMethod>, raw: Data, on transport: any Transport) {
        let method = request.method
        let handler = builtinHandler(for: method)
            ?? methodHandlers[method]
            ?? { _ in throw MCPError.methodNotFound("Unknown method: \(method)") }
        let work = Task<Data, Swift.Error> {
            try Task.checkCancellation()
            return try await handler(raw)
        }
        inFlightRequests[request.id] = work
        Task { await complete(request.id, of: work, on: transport) }
    }

    private func complete(
        _ id: ID, of work: Task<Data, Swift.Error>, on transport: any Transport
    ) async {
        let outcome = await work.result
        inFlightRequests.removeValue(forKey: id)
        switch outcome {
        case let .success(frame):
            await send(frame, on: transport)
        case .failure(is CancellationError):
            break
        case let .failure(error):
            let mcpError = error as? MCPError ?? .internalError(error.localizedDescription)
            if let frame = try? Self.encode(ErasedMethod.response(id: id, error: mcpError)) {
                await send(frame, on: transport)
            }
        }
    }

    private func handleNotification(_ note: Message<ErasedNotification>, raw: Data) {
        guard
            note.method == CancelledNotification.name,
            let cancelled = try? Self.wireDecoder.decode(
                Message<CancelledNotification>.self, from: raw
            )
        else { return }
        inFlightRequests.removeValue(forKey: cancelled.params.requestId)?.cancel()
    }

    // MARK: - Built-in methods

    private func builtinHandler(for method: String) -> (@Sendable (Data) async throws -> Data)? {
        switch method {
        case Initialize.name:
            { raw in try await self.processInitialize(raw) }
        case Ping.name:
            { raw in
                let request = try Self.wireDecoder.decode(Request<Ping>.self, from: raw)
                return try Self.encode(Ping.response(id: request.id))
            }
        default:
            nil
        }
    }

    private func processInitialize(_ raw: Data) throws -> Data {
        let request = try Self.wireDecoder.decode(Request<Initialize>.self, from: raw)
        guard !isInitialized else {
            throw MCPError.invalidRequest("Server is already initialized")
        }
        isInitialized = true
        let requested = request.params.protocolVersion
        let negotiated = Version.supported.contains(requested) ? requested : Version.latest
        let result = Initialize.Result(
            protocolVersion: negotiated,
            capabilities: capabilities,
            serverInfo: serverInfo
        )
        return try Self.encode(Initialize.response(id: request.id, result: result))
    }

    // MARK: - Liveness

    private func pingLoop(on transport: any Transport, _ config: ClientLiveness) async {
        while true {
            do {
                try await Task.sleep(for: config.interval)
            } catch {
                return
            }
            if missedPongs >= config.missedPongLimit {
                Log.info("declaring the client dead: \(missedPongs) pings with no traffic")
                await transport.disconnect()
                return
            }
            missedPongs += 1
            if let frame = try? Self.encode(Ping.request()) {
                await send(frame, on: transport)
            }
        }
    }

    // MARK: - Wire

    private func send(_ frame: Data, on transport: any Transport) async {
        try? await transport.send(frame)
    }

    private static let wireDecoder = JSONDecoder()
    private static let wireEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()

    private static func encode(_ value: some Encodable) throws -> Data {
        try wireEncoder.encode(value)
    }

    private static func parseErrorResponse(for raw: Data) -> Data {
        let object = (try? JSONSerialization.jsonObject(with: raw)) as? [String: Any]
        let id: ID =
            if let string = object?["id"] as? String {
                .string(string)
            } else if let number = object?["id"] as? Int {
                .number(number)
            } else {
                .random
            }
        let reply = ErasedMethod.response(id: id, error: .parseError("Invalid message format"))
        return (try? encode(reply)) ?? Data()
    }
}

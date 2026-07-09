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
/// Liveness (the owner's rewrite requirement): with a `PingLiveness`
/// config the server pings its client on an interval and disconnects the
/// transport after `missedPongLimit` pings with no response of any kind
/// (see `LivenessPinging`). Any inbound response counts as proof of life —
/// an SDK client answers server pings with methodNotFound (characterized),
/// and that is a live peer.
actor PreviewsMCPServer: MCPServing, LivenessPinging {
    private let serverInfo: Server.Info
    private let capabilities: Server.Capabilities
    private let liveness: PingLiveness?
    private var methodHandlers: [String: @Sendable (Data) async throws -> Data] = [:]
    private var transport: (any Transport)?
    private var receiveLoop: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var inFlightRequests: [UUID: (id: ID, task: Task<Data, Swift.Error>)] = [:]
    private var isInitialized = false
    var missedPongs = 0

    init(
        name: String, version: String,
        capabilities: Server.Capabilities = .init(),
        liveness: PingLiveness? = nil
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
            let request = try MCPWire.decoder.decode(Request<M>.self, from: raw)
            let result = try await handler(request.params)
            return try MCPWire.encode(M.response(id: request.id, result: result))
        }
        return self
    }

    func start(transport: any Transport) async throws {
        self.transport = transport
        try await transport.connect()
        receiveLoop = Task { await run(on: transport) }
        if let liveness {
            pinger = Task { await pingLoop(on: transport, liveness, peer: "client") }
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
        try await transport.send(try MCPWire.encode(notification))
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
                switch MCPWire.classify(raw) {
                case .response:
                    break
                case let .request(id, method):
                    dispatch(id: id, method: method, raw: raw, on: transport)
                case let .notification(method):
                    handleNotification(method: method, raw: raw)
                case let .unparseable(id):
                    let reply = Self.parseErrorResponse(id: id)
                    Task { await send(reply, on: transport) }
                }
            }
        } catch {}
        // In-flight handlers run to completion after peer disconnect, like
        // the SDK: daemon sessions persist across CLI invocations, so a
        // killed client's finishing render is a warm session, not waste.
        pinger?.cancel()
    }

    private func cancelInFlight() {
        for entry in inFlightRequests.values {
            entry.task.cancel()
        }
        inFlightRequests.removeAll()
    }

    private func dispatch(id: ID, method: String, raw: Data, on transport: any Transport) {
        let handler = builtinHandler(for: method)
            ?? methodHandlers[method]
            ?? { _ in throw MCPError.methodNotFound("Unknown method: \(method)") }
        let work = Task<Data, Swift.Error> {
            try Task.checkCancellation()
            return try await handler(raw)
        }
        // Keyed by token, not request id: a colliding id must neither orphan
        // the first task from cancellation nor deregister the second when
        // the first completes.
        let token = UUID()
        inFlightRequests[token] = (id, work)
        Task { await complete(token, id: id, of: work, on: transport) }
    }

    private func complete(
        _ token: UUID, id: ID, of work: Task<Data, Swift.Error>, on transport: any Transport
    ) async {
        let outcome = await work.result
        inFlightRequests.removeValue(forKey: token)
        switch outcome {
        case let .success(frame):
            await send(frame, on: transport)
        case .failure(is CancellationError):
            break
        case let .failure(error):
            let mcpError = error as? MCPError ?? .internalError(error.localizedDescription)
            if let frame = MCPWire.errorResponse(id: id, mcpError) {
                await send(frame, on: transport)
            }
        }
    }

    private func handleNotification(method: String, raw: Data) {
        guard
            method == CancelledNotification.name,
            let cancelled = try? MCPWire.decoder.decode(
                Message<CancelledNotification>.self, from: raw
            )
        else { return }
        for (token, entry) in inFlightRequests where entry.id == cancelled.params.requestId {
            entry.task.cancel()
            inFlightRequests.removeValue(forKey: token)
        }
    }

    // MARK: - Built-in methods

    private func builtinHandler(for method: String) -> (@Sendable (Data) async throws -> Data)? {
        switch method {
        case Initialize.name:
            { raw in try await self.processInitialize(raw) }
        case Ping.name:
            { raw in
                let request = try MCPWire.decoder.decode(Request<Ping>.self, from: raw)
                return try MCPWire.encode(Ping.response(id: request.id))
            }
        default:
            nil
        }
    }

    private func processInitialize(_ raw: Data) throws -> Data {
        let request = try MCPWire.decoder.decode(Request<Initialize>.self, from: raw)
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
        return try MCPWire.encode(Initialize.response(id: request.id, result: result))
    }

    // MARK: - Wire

    private func send(_ frame: Data, on transport: any Transport) async {
        try? await transport.send(frame)
    }

    private static func parseErrorResponse(id: ID?) -> Data {
        // Echo the malformed frame's id when one was recoverable, per
        // JSON-RPC, so the peer can correlate the error to its request.
        MCPWire.errorResponse(id: id ?? .random, .parseError("Invalid message format")) ?? Data()
    }
}

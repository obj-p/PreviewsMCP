import Foundation
import MCP
import PreviewsCore

/// In-house MCP client loop (rewrite stage 6). Replaces the SDK `Client`
/// on the daemon channel; the SDK's data types are kept. The client parity
/// suite runs every pinned behavior against both clients differentially.
///
/// Liveness (the pong-fed replacement for the notification-fed StallTimer):
/// with a `PingLiveness` config the client pings the daemon on an
/// interval, and ANY inbound frame — pong, response, notification — is
/// proof of life (see `LivenessPinging`). After `missedPongLimit` pings
/// with no traffic the client disconnects, which drains every pending
/// request continuation with an error instead of hanging forever.
/// Detection latency is bounded by the client's own ping cadence,
/// independent of the daemon's liveness interval.
///
/// Two deliberate improvements over the SDK client, both characterized in
/// the parity suite as divergences:
/// - A transport EOF or read error ALSO drains pending requests (the SDK
///   busy-spins on a dead transport).
/// - Server-initiated pings get a real empty-result pong, not
///   methodNotFound (the daemon accepts either as proof of life).
actor PreviewsMCPClient: MCPClienting, LivenessPinging {
    private let clientInfo: Client.Info
    private let liveness: PingLiveness?
    private var transport: (any Transport)?
    private var receiveLoop: Task<Void, Never>?
    private var pinger: Task<Void, Never>?
    private var pending: [ID: CheckedContinuation<Data, Swift.Error>] = [:]
    private var notificationHandlers: [String: [@Sendable (Data) async -> Void]] = [:]
    var missedPongs = 0
    private var isFinished = false

    init(name: String, version: String, liveness: PingLiveness? = nil) {
        clientInfo = Client.Info(name: name, version: version)
        self.liveness = liveness
    }

    @discardableResult
    func onNotification<N: MCP.Notification>(
        _: N.Type,
        handler: @escaping @Sendable (Message<N>) async throws -> Void
    ) -> Self {
        notificationHandlers[N.name, default: []].append { raw in
            guard let message = try? MCPWire.decoder.decode(Message<N>.self, from: raw) else {
                return
            }
            try? await handler(message)
        }
        return self
    }

    func connect(transport: any Transport) async throws -> Initialize.Result {
        self.transport = transport
        try await transport.connect()
        receiveLoop = Task { await run(on: transport) }
        if let liveness {
            // Started before the handshake so even a wedged initialize is
            // bounded: a full liveness window with no inbound traffic
            // disconnects, draining the pending request, and connect
            // throws instead of hanging forever.
            pinger = Task { await pingLoop(on: transport, liveness, peer: "daemon") }
        }
        let result = try await request(
            Initialize.request(.init(capabilities: .init(), clientInfo: clientInfo))
        )
        try await transport.send(MCPWire.encode(InitializedNotification.message(.init())))
        return result
    }

    func disconnect() async {
        pinger?.cancel()
        pinger = nil
        receiveLoop?.cancel()
        receiveLoop = nil
        drainPending(with: MCPError.internalError("Client disconnected"))
        await transport?.disconnect()
        transport = nil
    }

    func callToolStructured(
        name: String, arguments: [String: Value]? = nil
    ) async throws -> CallTool.Result {
        try await request(CallTool.request(.init(name: name, arguments: arguments)))
    }

    // MARK: - Requests

    private func request<M: MCP.Method>(_ request: Request<M>) async throws -> M.Result {
        guard let transport, !isFinished else {
            throw MCPError.internalError("Client connection not initialized")
        }
        let frame = try MCPWire.encode(request)
        // Register the continuation before the send suspends: the response
        // can arrive on the receive loop before send() returns.
        let raw: Data = try await withCheckedThrowingContinuation { continuation in
            pending[request.id] = continuation
            Task {
                do {
                    try await transport.send(frame)
                } catch {
                    await self.fail(id: request.id, with: error)
                }
            }
        }
        let response = try MCPWire.decoder.decode(Response<M>.self, from: raw)
        switch response.result {
        case let .success(value):
            return value
        case let .failure(error):
            throw error
        }
    }

    private func fail(id: ID, with error: Swift.Error) {
        pending.removeValue(forKey: id)?.resume(throwing: error)
    }

    private func drainPending(with error: Swift.Error) {
        isFinished = true
        let waiting = pending.values
        pending.removeAll()
        for continuation in waiting {
            continuation.resume(throwing: error)
        }
    }

    // MARK: - Receive loop

    private func run(on transport: any Transport) async {
        do {
            for try await raw in await transport.receive() {
                // The receive loop is the liveness ground truth: ANY inbound
                // frame proves the daemon's process is alive and writing.
                missedPongs = 0
                switch MCPWire.classify(raw) {
                case let .response(id):
                    pending.removeValue(forKey: id)?.resume(returning: raw)
                case let .request(id, method):
                    await answer(id: id, method: method, on: transport)
                case let .notification(method):
                    await dispatch(method: method, raw: raw)
                case .unparseable:
                    break
                }
            }
        } catch {}
        pinger?.cancel()
        drainPending(with: MCPError.internalError("Server disconnected"))
    }

    private func answer(id: ID, method: String, on transport: any Transport) async {
        let reply =
            method == Ping.name
                ? MCPWire.pong(id: id)
                : MCPWire.errorResponse(id: id, .methodNotFound("Unknown method: \(method)"))
        if let reply {
            try? await transport.send(reply)
        }
    }

    /// Handlers run inline so notification order is preserved (the stderr
    /// log forwarder depends on it); every registered handler is tiny.
    private func dispatch(method: String, raw: Data) async {
        for handler in notificationHandlers[method] ?? [] {
            await handler(raw)
        }
    }
}

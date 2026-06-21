import Foundation
import Network

/// Per-session app interface bound to loopback. This is the surface the streamed
/// MCP app (and a browser) connect to, separate from the agent MCP tools and the
/// CLI. Today it exposes a control endpoint that accepts normalized pointer
/// input and forwards it to an `InputSink`. The pixel stream is layered on the
/// same server later.
///
/// Control protocol: `POST /control` with a JSON body, one of
///   {"action":"tap","x":0.5,"y":0.5}
///   {"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}
public final class PreviewAppServer: @unchecked Sendable {
    private let sink: any InputSink
    private let queue = DispatchQueue(label: "com.previewsmcp.app-server")
    private var listener: NWListener?

    public init(sink: any InputSink) {
        self.sink = sink
    }

    /// Bind to 127.0.0.1 on an ephemeral port and start listening. Returns the
    /// assigned port.
    public func start() async throws -> UInt16 {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        params.allowLocalEndpointReuse = true

        let listener = try NWListener(using: params)
        self.listener = listener
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }

        return try await withCheckedThrowingContinuation { continuation in
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    listener.stateUpdateHandler = nil
                    if let port = listener.port?.rawValue {
                        continuation.resume(returning: port)
                    } else {
                        continuation.resume(throwing: PreviewAppServerError.noPort)
                    }
                case .failed(let error):
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: error)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            if let body = Self.completedBody(buffer) {
                self.dispatch(body)
                self.respondAndClose(connection)
                return
            }
            if isComplete || error != nil {
                self.respondAndClose(connection)
                return
            }
            self.receive(connection, buffer: buffer)
        }
    }

    /// Return the request body once the full headers + Content-Length bytes have
    /// arrived, otherwise nil.
    private static func completedBody(_ buffer: Data) -> Data? {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = buffer.range(of: separator) else { return nil }
        let header = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        let body = buffer[range.upperBound...]

        var contentLength = 0
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            contentLength = Int(line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)) ?? 0
        }
        guard body.count >= contentLength else { return nil }
        return Data(body.prefix(contentLength))
    }

    private func dispatch(_ body: Data) {
        guard let command = try? JSONDecoder().decode(ControlCommand.self, from: body) else { return }
        switch command.action {
        case "tap":
            if let x = command.x, let y = command.y {
                sink.tap(x: x, y: y)
            }
        case "drag":
            if let fromX = command.fromX, let fromY = command.fromY,
                let toX = command.toX, let toY = command.toY
            {
                sink.drag(fromX: fromX, fromY: fromY, toX: toX, toY: toY, steps: command.steps ?? 10)
            }
        default:
            break
        }
    }

    private func respondAndClose(_ connection: NWConnection) {
        let response = Data("HTTP/1.1 200 OK\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in
                connection.cancel()
            })
    }
}

private struct ControlCommand: Decodable {
    let action: String
    let x: Double?
    let y: Double?
    let fromX: Double?
    let fromY: Double?
    let toX: Double?
    let toY: Double?
    let steps: Int?
}

public enum PreviewAppServerError: Error {
    case noPort
}

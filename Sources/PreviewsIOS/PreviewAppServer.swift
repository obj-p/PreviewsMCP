import Foundation
import Network

/// Per-session app interface bound to loopback. This is the surface the streamed
/// MCP app (and a browser) connect to, separate from the agent MCP tools and the
/// CLI. It exposes:
///   - `POST /control`  normalized pointer input forwarded to an `InputSink`.
///   - `GET /stream.mjpeg`  an MJPEG stream of the shell composite (when a
///     `FrameSource` is provided).
///
/// Control bodies are JSON, one of
///   {"action":"tap","x":0.5,"y":0.5}
///   {"action":"drag","fromX":0.5,"fromY":0.7,"toX":0.5,"toY":0.3,"steps":12}
public final class PreviewAppServer: @unchecked Sendable {
    private let sink: any InputSink
    private let frameSource: (any FrameSource)?
    private let videoStream: AVCCVideoStream?
    private let streamIntervalMS: UInt64
    private let queue = DispatchQueue(label: "com.previewsmcp.app-server")
    private var listener: NWListener?
    private var connections: [NWConnection] = []
    private var streamTasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    public init(
        sink: any InputSink,
        frameSource: (any FrameSource)? = nil,
        videoStream: AVCCVideoStream? = nil,
        streamIntervalMS: UInt64 = 80
    ) {
        self.sink = sink
        self.frameSource = frameSource
        self.videoStream = videoStream
        self.streamIntervalMS = streamIntervalMS
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
                case .cancelled:
                    listener.stateUpdateHandler = nil
                    continuation.resume(throwing: PreviewAppServerError.cancelled)
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    public func stop() {
        queue.sync {
            streamTasks.values.forEach { $0.cancel() }
            streamTasks.removeAll()
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    // MARK: - Connection handling

    private func handle(_ connection: NWConnection) {
        connections.append(connection)
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .cancelled, .failed:
                self.queue.async {
                    let key = ObjectIdentifier(connection)
                    self.streamTasks[key]?.cancel()
                    self.streamTasks[key] = nil
                    self.connections.removeAll { $0 === connection }
                }
            default:
                break
            }
        }
        connection.start(queue: queue)
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data { buffer.append(data) }

            let separator = Data("\r\n\r\n".utf8)
            guard let headerRange = buffer.range(of: separator) else {
                if isComplete || error != nil {
                    connection.cancel()
                    return
                }
                self.receive(connection, buffer: buffer)
                return
            }

            let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
            let (method, path) = Self.requestLine(header)

            switch (method, path) {
            case ("GET", "/stream.mjpeg"):
                if let source = self.frameSource {
                    self.stream(connection, source: source)
                } else {
                    self.respond(connection, status: "503 Service Unavailable")
                }
            case ("GET", "/stream.avcc"):
                if let video = self.videoStream {
                    self.streamAVCC(connection, video: video)
                } else {
                    self.respond(connection, status: "503 Service Unavailable")
                }
            case ("POST", "/control"):
                let contentLength = Self.contentLength(header)
                let body = buffer[headerRange.upperBound...]
                if body.count >= contentLength {
                    self.dispatch(Data(body.prefix(contentLength)))
                    self.respond(connection, status: "200 OK")
                } else {
                    self.receive(connection, buffer: buffer)
                }
            default:
                self.respond(connection, status: "404 Not Found")
            }
        }
    }

    private static func requestLine(_ header: String) -> (method: String, path: String) {
        guard let firstLine = header.split(separator: "\r\n").first else { return ("", "") }
        let parts = firstLine.split(separator: " ")
        guard parts.count >= 2 else { return ("", "") }
        return (String(parts[0]), String(parts[1]))
    }

    private static func contentLength(_ header: String) -> Int {
        for line in header.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.drop(while: { $0 != ":" }).dropFirst().trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
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

    private func respond(_ connection: NWConnection, status: String) {
        let response = Data("HTTP/1.1 \(status)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() })
    }

    // MARK: - MJPEG stream

    private func stream(_ connection: NWConnection, source: any FrameSource) {
        let intervalMS = streamIntervalMS
        let task = Task { [weak self] in
            guard let self else { return }
            let head =
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            do {
                try await self.send(connection, Data(head.utf8))
                while true {
                    try Task.checkCancellation()
                    guard let jpeg = await source.nextFrame() else {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    var part = Data(
                        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8)
                    part.append(jpeg)
                    part.append(contentsOf: [0x0d, 0x0a])
                    try await self.send(connection, part)
                    try await Task.sleep(for: .milliseconds(intervalMS))
                }
            } catch {
                connection.cancel()
            }
        }
        queue.async { self.streamTasks[ObjectIdentifier(connection)] = task }
    }

    // MARK: - H.264 (avcC) stream

    private func streamAVCC(_ connection: NWConnection, video: AVCCVideoStream) {
        let task = Task { [weak self] in
            guard let self else { return }
            let id = ObjectIdentifier(connection)
            let head =
                "HTTP/1.1 200 OK\r\n"
                + "Content-Type: application/octet-stream\r\n"
                + "Cache-Control: no-cache, no-store\r\n"
                + "Connection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n"
            do {
                try await self.send(connection, Data(head.utf8))
                if let seed = await self.frameSource?.nextFrame() {
                    try await self.send(connection, AVCCEnvelope.seed(jpeg: seed))
                }
                video.addSubscriber(id) { data in
                    connection.send(content: data, completion: .contentProcessed { _ in })
                }
                // Encoded chunks arrive via the subscriber sink; hold the
                // connection open until it is cancelled on close (or teardown).
                while true {
                    try Task.checkCancellation()
                    try await Task.sleep(for: .seconds(30))
                }
            } catch {
                video.removeSubscriber(id)
                connection.cancel()
            }
        }
        queue.async { self.streamTasks[ObjectIdentifier(connection)] = task }
    }

    private func send(_ connection: NWConnection, _ data: Data) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(
                content: data,
                completion: .contentProcessed { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                })
        }
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
    case cancelled
}

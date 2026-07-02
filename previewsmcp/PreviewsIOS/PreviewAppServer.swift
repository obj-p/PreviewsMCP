import Foundation
import Network
import PreviewsCore

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
                case let .failed(error):
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
            if !streamTasks.isEmpty {
                Log.info("appserver: stop() cancelling \(streamTasks.count) live stream task(s)")
            }
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
                // A dropped STREAM connection is the #320 flake trigger, so it
                // must be visible in serve.log; one-shot request closes are
                // routine and stay quiet.
                if case let .failed(error) = state {
                    Log.warn("appserver: connection \(Self.shortID(connection)) failed: \(error)")
                }
                queue.async {
                    let key = ObjectIdentifier(connection)
                    if let task = self.streamTasks[key] {
                        Log.warn(
                            "appserver: stream connection \(Self.shortID(connection)) reached \(state) — cancelling its stream task"
                        )
                        task.cancel()
                    }
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

    private static func shortID(_ connection: NWConnection) -> String {
        String(UInt(bitPattern: ObjectIdentifier(connection).hashValue) & 0xFFFF, radix: 16)
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
                receive(connection, buffer: buffer)
                return
            }

            let header = String(decoding: buffer[..<headerRange.lowerBound], as: UTF8.self)
            let (method, path) = Self.requestLine(header)

            switch (method, path) {
            case ("GET", "/"), ("GET", "/index.html"):
                respondHTML(connection, Self.clientHTML)
            case ("GET", "/stream.mjpeg"):
                if let source = frameSource {
                    stream(connection, source: source)
                } else {
                    respond(connection, status: "503 Service Unavailable")
                }
            case ("GET", "/stream.avcc"):
                if let video = videoStream {
                    streamAVCC(connection, video: video)
                } else {
                    respond(connection, status: "503 Service Unavailable")
                }
            case ("POST", "/control"):
                let contentLength = Self.contentLength(header)
                let body = buffer[headerRange.upperBound...]
                if body.count >= contentLength {
                    dispatch(Data(body.prefix(contentLength)))
                    respond(connection, status: "200 OK")
                } else {
                    receive(connection, buffer: buffer)
                }
            default:
                respond(connection, status: "404 Not Found")
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
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    /// The self-contained viewer page served at `GET /`: it decodes
    /// `/stream.avcc` via WebCodecs (MJPEG fallback) and forwards pointer input
    /// to `/control`, all same-origin on this loopback port.
    static let clientHTML = Data(PackageResources.client_html)

    private func respondHTML(_ connection: NWConnection, _ html: Data) {
        let header =
            "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\n"
                + "Content-Length: \(html.count)\r\nConnection: close\r\n\r\n"
        var response = Data(header.utf8)
        response.append(html)
        connection.send(
            content: response,
            completion: .contentProcessed { _ in connection.cancel() }
        )
    }

    // MARK: - MJPEG stream

    private func stream(_ connection: NWConnection, source: any FrameSource) {
        let intervalMS = streamIntervalMS
        let cid = Self.shortID(connection)
        let task = Task { [weak self] in
            guard let self else { return }
            let head =
                "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: multipart/x-mixed-replace; boundary=frame\r\n"
                    + "Cache-Control: no-cache\r\nConnection: close\r\n\r\n"
            var frames = 0
            do {
                try await send(connection, Data(head.utf8))
                while true {
                    try Task.checkCancellation()
                    guard let jpeg = await source.nextFrame() else {
                        try await Task.sleep(for: .milliseconds(100))
                        continue
                    }
                    var part = Data(
                        "--frame\r\nContent-Type: image/jpeg\r\nContent-Length: \(jpeg.count)\r\n\r\n".utf8
                    )
                    part.append(jpeg)
                    part.append(contentsOf: [0x0D, 0x0A])
                    try await send(connection, part)
                    frames += 1
                    if frames == 1 {
                        Log.info("appserver: mjpeg \(cid) first frame sent (\(jpeg.count) bytes)")
                    }
                    try await Task.sleep(for: .milliseconds(intervalMS))
                }
            } catch {
                // The visible face of the #320 flake: whatever lands here kills
                // the stream a client may still be awaiting.
                Log.warn(
                    "appserver: mjpeg \(cid) stream ended after \(frames) frame(s) — \(Self.describe(error))"
                )
                connection.cancel()
            }
        }
        queue.async { self.streamTasks[ObjectIdentifier(connection)] = task }
    }

    private static func describe(_ error: Error) -> String {
        if error is CancellationError { return "cancelled (task)" }
        return String(describing: error)
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
                try await send(connection, Data(head.utf8))
                if let seed = await frameSource?.nextFrame() {
                    try await send(connection, AVCCEnvelope.seed(jpeg: seed))
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
                Log.warn(
                    "appserver: avcc \(Self.shortID(connection)) stream ended — \(Self.describe(error))"
                )
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
                }
            )
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

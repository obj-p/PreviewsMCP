import Foundation

/// Bounded raw reading of a streaming HTTP response over a plain blocking
/// socket.
///
/// Exists because URLSession is unusable for consuming the app server's
/// streaming endpoints from tests: its multipart/x-mixed-replace handling is
/// timing-dependent (a fully-buffered part throws a bare NSURLError -1 or
/// delivers nothing — root-caused as #350), and `AsyncBytes` parked inside
/// `next()` cannot be cancelled, so a dead transfer throws NSURLError -999 or
/// wedges the test. A raw socket with `SO_RCVTIMEO` plus a whole-read deadline
/// is timing-independent and asserts the actual wire framing.
public enum RawHTTP {
    public struct SampleError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? {
            message
        }
    }

    private struct Head {
        let fd: Int32
        let text: String
        let bodyPrefix: Data
    }

    /// Open a blocking socket to 127.0.0.1:port, GET path, and read until the
    /// response head is complete. Returns the still-open fd (the caller closes
    /// it), the head text, and any body bytes read alongside the head.
    /// Validates a 200 status. Bounded by `deadline` measured from `clock`.
    private static func openAndReadHead(
        port: Int, path: String, clock: ContinuousClock.Instant, deadline: Duration
    ) throws -> Head {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SampleError(message: "socket() failed errno=\(errno)") }
        var keepOpen = false
        defer { if !keepOpen { close(fd) } }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = UInt16(port).bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            throw SampleError(message: "connect(127.0.0.1:\(port)) failed errno=\(errno)")
        }
        let request = "GET \(path) HTTP/1.1\r\nHost: 127.0.0.1:\(port)\r\nConnection: close\r\n\r\n"
        _ = request.withCString { write(fd, $0, strlen($0)) }

        var received = Data()
        let terminator = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 16384)
        while ContinuousClock.now - clock < deadline {
            let n = read(fd, &chunk, chunk.count)
            if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
            guard n > 0 else {
                throw SampleError(message: "stream closed before response head (read=\(n) errno=\(errno))")
            }
            received.append(contentsOf: chunk[0 ..< n])
            if let range = received.range(of: terminator) {
                let text = String(decoding: received[..<range.lowerBound], as: UTF8.self)
                guard text.hasPrefix("HTTP/1.1 200") else {
                    throw SampleError(message: "unexpected status: \(text.prefix(40))")
                }
                keepOpen = true
                return Head(fd: fd, text: text, bodyPrefix: received[range.upperBound...])
            }
        }
        throw SampleError(message: "no response head within deadline (\(received.count) bytes)")
    }

    /// Issue a GET and collect the response head plus up to `bodyLimit` body
    /// bytes, then close. A streaming server sees a mid-stream disconnect,
    /// which is an ordinary client departure.
    public static func sample(
        port: Int, path: String, bodyLimit: Int, deadline: Duration
    ) async throws -> (head: String, body: Data) {
        try await Task.detached {
            let clock = ContinuousClock.now
            let head = try openAndReadHead(port: port, path: path, clock: clock, deadline: deadline)
            defer { close(head.fd) }
            var body = head.bodyPrefix
            var chunk = [UInt8](repeating: 0, count: 16384)
            while body.count < bodyLimit, ContinuousClock.now - clock < deadline {
                let n = read(head.fd, &chunk, chunk.count)
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard n > 0 else {
                    throw SampleError(message: "stream closed early after \(body.count) body bytes")
                }
                body.append(contentsOf: chunk[0 ..< n])
            }
            return (head.text, body)
        }.value
    }

    /// Issue a GET and stream the body to `consume` chunk by chunk until it
    /// returns false (done) or `deadline` elapses, then close. `onConnected`
    /// fires once, just before the first body bytes are delivered — the point
    /// the response is live so the caller can drive the server to emit more.
    /// Returns the response head text (for content-type assertions). Throws if
    /// the stream closes before `consume` signals done.
    @discardableResult
    public static func stream(
        port: Int, path: String, deadline: Duration,
        onConnected: @escaping @Sendable () async -> Void,
        consume: @escaping @Sendable (Data) -> Bool
    ) async throws -> String {
        try await Task.detached {
            let clock = ContinuousClock.now
            let head = try openAndReadHead(port: port, path: path, clock: clock, deadline: deadline)
            defer { close(head.fd) }
            var fired = false
            func fireOnce() async {
                if !fired {
                    fired = true
                    await onConnected()
                }
            }
            if !head.bodyPrefix.isEmpty {
                await fireOnce()
                if !consume(head.bodyPrefix) { return head.text }
            }
            var chunk = [UInt8](repeating: 0, count: 16384)
            while ContinuousClock.now - clock < deadline {
                let n = read(head.fd, &chunk, chunk.count)
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard n > 0 else {
                    throw SampleError(message: "stream closed before consume signalled done")
                }
                await fireOnce()
                if !consume(Data(chunk[0 ..< n])) { return head.text }
            }
            return head.text
        }.value
    }
}

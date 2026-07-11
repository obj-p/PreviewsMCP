import Foundation

/// Bounded raw sampling of a streaming HTTP response over a plain blocking
/// socket: status line, headers, and up to `bodyLimit` body bytes.
///
/// Exists because URLSession is unusable for sampling
/// multipart/x-mixed-replace: its multipart handling is timing-dependent, and
/// once a full part sits buffered before the consumer starts iterating
/// (loopback burst + a loaded machine), `AsyncBytes` either throws a bare
/// NSURLError -1 or delivers no bytes while the task reports no error —
/// reproduced deterministically and root-caused as #350. A raw read is
/// timing-independent and asserts the actual wire framing browser clients
/// consume.
public enum RawHTTP {
    public struct SampleError: Error, LocalizedError {
        public let message: String
        public var errorDescription: String? {
            message
        }
    }

    /// Issue a GET and collect the response head plus up to `bodyLimit` body
    /// bytes. `SO_RCVTIMEO` bounds each read and `deadline` bounds the whole
    /// sample, so a stalled stream fails loudly instead of hanging. The socket
    /// is closed on return; a streaming server sees a mid-stream disconnect,
    /// which is an ordinary client departure.
    public static func sample(
        port: Int, path: String, bodyLimit: Int, deadline: Duration
    ) async throws -> (head: String, body: Data) {
        try await Task.detached {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { throw SampleError(message: "socket() failed errno=\(errno)") }
            defer { close(fd) }
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
            let headTerminator = Data("\r\n\r\n".utf8)
            var headEnd: Range<Data.Index>?
            let clock = ContinuousClock.now
            var chunk = [UInt8](repeating: 0, count: 16384)
            while ContinuousClock.now - clock < deadline {
                let n = read(fd, &chunk, chunk.count)
                if n < 0, errno == EAGAIN || errno == EWOULDBLOCK { continue }
                guard n > 0 else {
                    throw SampleError(
                        message: "stream closed early after \(received.count) bytes (read=\(n) errno=\(errno))"
                    )
                }
                received.append(contentsOf: chunk[0 ..< n])
                if headEnd == nil { headEnd = received.range(of: headTerminator) }
                if let headEnd, received.count - headEnd.upperBound >= bodyLimit { break }
            }
            guard let headEnd else {
                throw SampleError(message: "no response head within deadline (\(received.count) bytes)")
            }
            let head = String(decoding: received[..<headEnd.lowerBound], as: UTF8.self)
            guard head.hasPrefix("HTTP/1.1 200") else {
                throw SampleError(message: "unexpected status: \(head.prefix(40))")
            }
            return (head, received[headEnd.upperBound...])
        }.value
    }
}

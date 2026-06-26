import Darwin
import Foundation

/// Minimal RFB 3.8 client. Send-side only: handshake → KeyEvent /
/// PointerEvent. Server-to-client messages (FramebufferUpdate,
/// SetColourMapEntries, Bell, ServerCutText) are drained without
/// rendering — we don't need pixels here, just a control channel that
/// reaches the guest's input devices.
///
/// References:
/// - RFC 6143 (The Remote Framebuffer Protocol)
public final class RFBClient {
    public struct Endpoint: Sendable {
        public let host: String
        public let port: UInt16
        public init(host: String, port: UInt16) {
            self.host = host; self.port = port
        }
    }

    private var fd: Int32 = -1

    public init() {}

    deinit {
        if fd >= 0 { Darwin.close(fd) }
    }

    public func connect(to endpoint: Endpoint, timeout: TimeInterval = 10) throws {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = endpoint.port.bigEndian
        guard endpoint.host.withCString({ inet_pton(AF_INET, $0, &addr.sin_addr) }) == 1 else {
            throw VMError("inet_pton: not a valid IPv4 host '\(endpoint.host)'")
        }

        // Spin-wait connect with a deadline. A failed connect(2) leaves the
        // stream socket unusable on BSD, so each attempt needs a fresh fd.
        let deadline = Date().addingTimeInterval(timeout)
        var lastError: Int32 = 0
        repeat {
            let socketFd = socket(AF_INET, SOCK_STREAM, 0)
            guard socketFd >= 0 else { throw posix("socket()") }
            let result = withUnsafePointer(to: &addr) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(socketFd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 {
                fd = socketFd
                Log.debug("RFB connected to \(endpoint.host):\(endpoint.port) on fd \(socketFd)")
                return
            }
            lastError = errno
            Darwin.close(socketFd)
            if lastError == EINTR || lastError == ECONNREFUSED {
                usleep(100_000) // 100ms, then retry on a fresh fd
                continue
            }
            throw posix("connect()", code: lastError)
        } while Date() < deadline

        throw VMError(
            "connect() to localhost:\(endpoint.port) timed out after \(Int(timeout))s (last errno: \(lastError))"
        )
    }

    public func handshake() throws {
        // ProtocolVersion: server sends 12 bytes "RFB 003.008\n".
        let serverBanner = try readExactly(12)
        let banner = String(data: serverBanner, encoding: .ascii) ?? "<binary>"
        Log.debug("RFB server banner: \(banner.trimmingCharacters(in: .whitespacesAndNewlines))")
        try writeAll(Data("RFB 003.008\n".utf8))

        // Security types: 1-byte count, then count bytes of types.
        // count == 0 means error, followed by a 4-byte reason length
        // and reason string.
        let countByte = try readExactly(1)
        let count = Int(countByte[0])
        guard count > 0 else {
            let reasonLen = try readBigEndianUInt32()
            let reason = try readExactly(Int(reasonLen))
            throw VMError(
                "VNC handshake failed: \(String(data: reason, encoding: .utf8) ?? "<binary>")"
            )
        }
        let types = try readExactly(count)
        guard types.contains(1) else {
            throw VMError(
                "VNC server doesn't advertise security type 1 (None); advertised: \(Array(types))"
            )
        }

        // Select type 1 (None).
        try writeAll(Data([1]))

        // SecurityResult: 4 bytes, big-endian uint32. 0 = OK.
        let result = try readBigEndianUInt32()
        guard result == 0 else {
            // Failure path: 3.8 sends a reason string after the result.
            let reasonLen = try readBigEndianUInt32()
            let reason = try readExactly(Int(reasonLen))
            throw VMError(
                "VNC security handshake failed (\(result)): \(String(data: reason, encoding: .utf8) ?? "<binary>")"
            )
        }

        // ClientInit: 1-byte shared flag. 1 = allow other clients.
        try writeAll(Data([1]))

        // ServerInit: width(2) + height(2) + pixelFormat(16) + nameLen(4) + name(nameLen).
        let header = try readExactly(24)
        let nameLen = beUInt32(header.subdata(in: 20 ..< 24))
        if nameLen > 0 {
            _ = try readExactly(Int(nameLen))
        }
        let width = beUInt16(header.subdata(in: 0 ..< 2))
        let height = beUInt16(header.subdata(in: 2 ..< 4))
        Log.info("RFB handshake complete — framebuffer \(width)×\(height)")
    }

    /// Send a key event. `keysym` is an X11 keysym (see RFBClient.KeySym).
    public func sendKeyEvent(keysym: UInt32, down: Bool) throws {
        var buf = Data(capacity: 8)
        buf.append(4) // message type: KeyEvent
        buf.append(down ? 1 : 0)
        buf.append(contentsOf: [0, 0]) // padding
        appendUInt32BE(keysym, to: &buf)
        try writeAll(buf)
    }

    /// Press + release a single key.
    public func tapKey(keysym: UInt32) throws {
        try sendKeyEvent(keysym: keysym, down: true)
        try sendKeyEvent(keysym: keysym, down: false)
    }

    /// Send a pointer event. `buttonMask` bit 0 = left, bit 1 = middle,
    /// bit 2 = right. Coordinates are in framebuffer pixels (not window
    /// coords, which is the win over the NSEvent route).
    public func sendPointerEvent(buttonMask: UInt8, x: UInt16, y: UInt16) throws {
        var buf = Data(capacity: 6)
        buf.append(5) // message type: PointerEvent
        buf.append(buttonMask)
        appendUInt16BE(x, to: &buf)
        appendUInt16BE(y, to: &buf)
        try writeAll(buf)
    }

    /// Left-click: move (no button), down, up. The move first lets SA
    /// register the cursor position before the down event arrives.
    public func leftClick(x: UInt16, y: UInt16) throws {
        try sendPointerEvent(buttonMask: 0, x: x, y: y)
        try sendPointerEvent(buttonMask: 1, x: x, y: y)
        try sendPointerEvent(buttonMask: 0, x: x, y: y)
    }

    // MARK: - Socket I/O

    private func writeAll(_ data: Data) throws {
        try data.withUnsafeBytes { rawBuf in
            var sent = 0
            let total = rawBuf.count
            while sent < total {
                let n = Darwin.write(fd, rawBuf.baseAddress!.advanced(by: sent), total - sent)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw posix("write()")
                }
                if n == 0 { throw VMError("write() returned 0 — socket closed") }
                sent += n
            }
        }
    }

    private func readExactly(_ count: Int) throws -> Data {
        var buf = Data(count: count)
        try buf.withUnsafeMutableBytes { rawBuf in
            var read = 0
            while read < count {
                let n = Darwin.read(fd, rawBuf.baseAddress!.advanced(by: read), count - read)
                if n < 0 {
                    if errno == EINTR { continue }
                    throw self.posix("read()")
                }
                if n == 0 { throw VMError("read() returned 0 — socket closed") }
                read += n
            }
        }
        return buf
    }

    private func readBigEndianUInt32() throws -> UInt32 {
        beUInt32(try readExactly(4))
    }

    private func posix(_ call: String, code: Int32 = errno) -> VMError {
        VMError("\(call) failed: errno=\(code) (\(String(cString: strerror(code))))")
    }
}

// MARK: - X11 keysyms

public extension RFBClient {
    enum KeySym {
        public static let backspace: UInt32 = 0xFF08
        public static let tab: UInt32 = 0xFF09
        public static let returnKey: UInt32 = 0xFF0D
        public static let escape: UInt32 = 0xFF1B
        public static let leftArrow: UInt32 = 0xFF51
        public static let upArrow: UInt32 = 0xFF52
        public static let rightArrow: UInt32 = 0xFF53
        public static let downArrow: UInt32 = 0xFF54
        public static let space: UInt32 = 0x0020
        // F-keys, X11 standard.
        public static let f1: UInt32 = 0xFFBE
        public static let f2: UInt32 = 0xFFBF
        public static let f3: UInt32 = 0xFFC0
        public static let f4: UInt32 = 0xFFC1
        public static let f5: UInt32 = 0xFFC2
        public static let f6: UInt32 = 0xFFC3
        public static let f7: UInt32 = 0xFFC4
        public static let f8: UInt32 = 0xFFC5
        public static let f9: UInt32 = 0xFFC6
        public static let f10: UInt32 = 0xFFC7
        public static let f11: UInt32 = 0xFFC8
        public static let f12: UInt32 = 0xFFC9
        public static let shiftLeft: UInt32 = 0xFFE1
        public static let shiftRight: UInt32 = 0xFFE2
        public static let controlLeft: UInt32 = 0xFFE3
        public static let controlRight: UInt32 = 0xFFE4
        // Empirically against `_VZVNCServer`: Cmd maps to 0xFFE9/0xFFEA
        // and Option maps to 0xFFE7/0xFFE8. The X11 standard names
        // differ (0xFFE9 = Alt_L, 0xFFE7 = Meta_L) but this mapping is
        // what the macOS VZ-side VNC server accepts.
        public static let optionLeft: UInt32 = 0xFFE7
        public static let optionRight: UInt32 = 0xFFE8
        public static let commandLeft: UInt32 = 0xFFE9
        public static let commandRight: UInt32 = 0xFFEA

        /// Printable ASCII passthrough. Returns nil for non-ASCII.
        public static func character(_ c: Character) -> UInt32? {
            guard c.isASCII, let scalar = c.unicodeScalars.first else { return nil }
            let v = scalar.value
            return (v >= 0x20 && v <= 0x7E) ? v : nil
        }
    }
}

// MARK: - Byte helpers

private func appendUInt16BE(_ value: UInt16, to data: inout Data) {
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func appendUInt32BE(_ value: UInt32, to data: inout Data) {
    data.append(UInt8((value >> 24) & 0xFF))
    data.append(UInt8((value >> 16) & 0xFF))
    data.append(UInt8((value >> 8) & 0xFF))
    data.append(UInt8(value & 0xFF))
}

private func beUInt16(_ data: Data) -> UInt16 {
    let bytes = Array(data)
    return UInt16(bytes[0]) << 8 | UInt16(bytes[1])
}

private func beUInt32(_ data: Data) -> UInt32 {
    let bytes = Array(data)
    return UInt32(bytes[0]) << 24 | UInt32(bytes[1]) << 16 | UInt32(bytes[2]) << 8 | UInt32(bytes[3])
}

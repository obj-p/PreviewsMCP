import Darwin
import System

/// POSIX plumbing for the daemon's Unix-domain-socket channel (rewrite
/// stage 3). Produces plain file descriptors that `FramedTransport` carries
/// as-is, replacing `NWListener`/`NWConnection` + the SDK `NetworkTransport`
/// at cutover.
///
/// Callers own every returned descriptor and must close it. All descriptors
/// are marked close-on-exec so daemon children (compilers, simulators) do
/// not inherit the channel — best effort: Darwin has no atomic SOCK_CLOEXEC
/// or accept4, so a spawn racing the fcntl can inherit the descriptor for
/// that window.
enum DaemonSocket {
    /// Bind and listen on `path`. The listener is non-blocking so
    /// `accept(on:)` polls cancellably. Stale-socket-file cleanup stays
    /// with the caller (it must first verify no live daemon is listening).
    static func listen(at path: String, backlog: Int32 = 16) throws -> FileDescriptor {
        let listener = try makeSocket()
        try closingOnThrow(listener) {
            try withSockaddrUn(path) { address, length in
                guard Darwin.bind(listener.rawValue, address, length) == 0 else {
                    throw Errno(rawValue: errno)
                }
            }
            guard Darwin.listen(listener.rawValue, backlog) == 0 else {
                throw Errno(rawValue: errno)
            }
            try listener.setNonBlocking()
        }
        return listener
    }

    /// Accept one connection, polling the non-blocking listener so the
    /// call is cancellable (a blocking accept would park a cooperative
    /// thread with no way to interrupt it).
    static func accept(on listener: FileDescriptor) async throws -> FileDescriptor {
        while true {
            try Task.checkCancellation()
            let raw = Darwin.accept(listener.rawValue, nil, nil)
            if raw >= 0 {
                let connection = FileDescriptor(rawValue: raw)
                try closingOnThrow(connection) {
                    try connection.setCloseOnExec()
                }
                return connection
            }
            switch Errno(rawValue: errno) {
            case .wouldBlock:
                try await Task.sleep(for: .milliseconds(10))
            case .interrupted, .connectionAbort:
                continue
            case let failure:
                throw failure
            }
        }
    }

    /// Dial the daemon at `path`. Blocking, but a UDS connect resolves
    /// immediately: it either succeeds or fails with ENOENT/ECONNREFUSED.
    static func connect(to path: String) throws -> FileDescriptor {
        let socket = try makeSocket()
        try closingOnThrow(socket) {
            try withSockaddrUn(path) { address, length in
                guard Darwin.connect(socket.rawValue, address, length) == 0 else {
                    throw Errno(rawValue: errno)
                }
            }
        }
        return socket
    }

    private static func makeSocket() throws -> FileDescriptor {
        let raw = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard raw >= 0 else { throw Errno(rawValue: errno) }
        let socket = FileDescriptor(rawValue: raw)
        try closingOnThrow(socket) {
            try socket.setCloseOnExec()
        }
        return socket
    }

    private static func closingOnThrow(
        _ descriptor: FileDescriptor, _ body: () throws -> Void
    ) throws {
        do {
            try body()
        } catch {
            try? descriptor.close()
            throw error
        }
    }

    private static func withSockaddrUn(
        _ path: String,
        _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> Void
    ) throws {
        var address = sockaddr_un()
        let capacity = MemoryLayout.size(ofValue: address.sun_path) - 1
        let bytes = Array(path.utf8)
        guard bytes.count <= capacity else { throw Errno(rawValue: ENAMETOOLONG) }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            destination.copyBytes(from: bytes)
        }
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rebound in
                try body(rebound, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }
}

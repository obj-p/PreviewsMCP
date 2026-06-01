import PreviewsJITLinkCxx

public final class JITSession {
    private let handle: OpaquePointer

    public init() throws {
        var session: OpaquePointer?
        if let error = previewsmcp_jit_session_create(&session) {
            throw JITLinkError.failed(error.string())
        }
        guard let session else {
            throw JITLinkError.failed("no session returned")
        }
        handle = session
    }

    public func addObject(path: String) throws {
        if let error = previewsmcp_jit_session_add_object(handle, path) {
            throw JITLinkError.failed(error.string())
        }
    }

    public func address(of symbol: String) throws -> UInt64 {
        var address: UInt64 = 0
        if let error = previewsmcp_jit_session_lookup(handle, symbol, &address) {
            throw JITLinkError.failed(error.string())
        }
        return address
    }

    public func call<T: FixedWidthInteger>(symbol: String) throws -> T {
        guard let pointer = UnsafeRawPointer(bitPattern: UInt(try address(of: symbol))) else {
            throw JITLinkError.failed("symbol \(symbol) resolved to null")
        }
        let function = unsafeBitCast(pointer, to: (@convention(c) () -> UInt64).self)
        var raw = function()
        return withUnsafeBytes(of: &raw) { $0.load(as: T.self) }
    }
}

public enum JITLinkError: Error {
    case failed(String)
}

private extension UnsafePointer where Pointee == CChar {
    func string() -> String {
        defer { previewsmcp_jit_dispose_string(self) }
        return String(cString: self)
    }
}

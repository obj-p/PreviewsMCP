import Foundation
import PreviewsJITLinkCxx

public final class JITSession {
    private let handle: OpaquePointer

    private static func orcRuntimePath() throws -> String {
        guard
            let path = Bundle.module
                .url(forResource: "liborc_rt_osx", withExtension: "a")?.path
        else {
            throw JITLinkError.failed("orc runtime archive missing from bundle")
        }
        return path
    }

    public init() throws {
        var session: OpaquePointer?
        if let error = previewsmcp_jit_session_create(&session, try Self.orcRuntimePath()) {
            throw JITLinkError.failed(error.string())
        }
        guard let session else {
            throw JITLinkError.failed("no session returned")
        }
        handle = session
    }

    deinit {
        previewsmcp_jit_session_destroy(handle)
    }

    public static func bundledAgentPath() throws -> String {
        let buildDir = Bundle.module.bundleURL.deletingLastPathComponent()
        let agent = buildDir.appendingPathComponent("PreviewAgent")
        guard FileManager.default.isExecutableFile(atPath: agent.path) else {
            throw JITLinkError.failed("PreviewAgent binary not found at \(agent.path)")
        }
        return agent.path
    }

    public init(remoteAgentPath: String) throws {
        var session: OpaquePointer?
        if let error = previewsmcp_jit_remote_session_create(&session, remoteAgentPath, try Self.orcRuntimePath()) {
            throw JITLinkError.failed(error.string())
        }
        guard let session else {
            throw JITLinkError.failed("no session returned")
        }
        handle = session
    }

    public func runMain(symbol: String) throws -> Int32 {
        var result: Int32 = 0
        if let error = previewsmcp_jit_session_run_main(handle, symbol, &result) {
            throw JITLinkError.failed(error.string())
        }
        return result
    }

    public func runOnMain(symbol: String) throws -> Int32 {
        var result: Int32 = 0
        if let error = previewsmcp_jit_session_run_on_main(handle, symbol, &result) {
            throw JITLinkError.failed(error.string())
        }
        return result
    }

    public func writePointer(at address: UInt64, value: UInt64) throws {
        if let error = previewsmcp_jit_session_write_pointer(handle, address, value) {
            throw JITLinkError.failed(error.string())
        }
    }

    public func addObject(path: String) throws {
        if let error = previewsmcp_jit_session_add_object(handle, path) {
            throw JITLinkError.failed(error.string())
        }
    }

    public func addArchive(path: String) throws {
        if let error = previewsmcp_jit_session_add_archive(handle, path) {
            throw JITLinkError.failed(error.string())
        }
    }

    public func addDylib(path: String) throws {
        if let error = previewsmcp_jit_session_add_dylib(handle, path) {
            throw JITLinkError.failed(error.string())
        }
    }

    /// Start a fresh generation: subsequent `addObject`/`addArchive`/`addDylib`/`runOnMain`
    /// target a new `JITDylib` on the same agent, and the next run re-runs `LLJIT::initialize`
    /// on it (registers `__swift5_*`). Lets one agent serve many edits (capped-persistent).
    public func newGeneration() throws {
        if let error = previewsmcp_jit_session_new_generation(handle) {
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

@available(*, unavailable)
extension JITSession: Sendable {}

public enum JITLinkError: Error, LocalizedError {
    case failed(String)

    public var errorDescription: String? {
        switch self {
        case .failed(let message):
            return "JIT link failed: \(message)"
        }
    }
}

private extension UnsafePointer where Pointee == CChar {
    func string() -> String {
        defer { previewsmcp_jit_dispose_string(self) }
        return String(cString: self)
    }
}

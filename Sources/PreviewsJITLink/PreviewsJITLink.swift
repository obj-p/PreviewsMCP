import PreviewsJITLinkCxx

public enum PreviewsJITLink {
    public static func mainDylibName() throws -> String {
        var name: UnsafeMutablePointer<CChar>?
        if let error = previewsmcp_jit_main_dylib_name(&name) {
            throw JITLinkError.jitCreationFailed(error.string())
        }
        guard let name else {
            throw JITLinkError.jitCreationFailed("no name returned")
        }
        return UnsafePointer(name).string()
    }

    public static func targetTriple() -> String {
        previewsmcp_jit_target_triple().string()
    }

    public static func linkAndCall<T>(objectPath: String, symbol: String) throws -> T {
        var raw: UInt64 = 0
        if let error = previewsmcp_jit_link_and_call(objectPath, symbol, &raw) {
            throw JITLinkError.linkFailed(error.string())
        }
        return withUnsafeBytes(of: &raw) { $0.load(as: T.self) }
    }
}

public enum JITLinkError: Error {
    case jitCreationFailed(String)
    case linkFailed(String)
}

private extension UnsafePointer where Pointee == CChar {
    func string() -> String {
        defer { previewsmcp_jit_dispose_string(self) }
        return String(cString: self)
    }
}

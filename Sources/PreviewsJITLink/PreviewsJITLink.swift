import PreviewsJITLinkCxx

public enum PreviewsJITLink {
    public static func mainDylibName() throws -> String {
        let result = previewsmcp_jit_main_dylib_name()
        guard let name = result.value else {
            throw JITLinkError.jitCreationFailed(result.error?.string() ?? "")
        }
        return name.string()
    }

    public static func targetTriple() -> String {
        previewsmcp_jit_target_triple().string()
    }
}

public enum JITLinkError: Error {
    case jitCreationFailed(String)
}

private extension UnsafePointer where Pointee == CChar {
    func string() -> String {
        defer { previewsmcp_jit_dispose_string(self) }
        return String(cString: self)
    }
}

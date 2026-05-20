import PreviewsJITLinkCxx

public enum PreviewsJITLink {
    public static func targetTriple() -> String {
        let cString = previewsmcp_jit_target_triple()
        defer { previewsmcp_jit_dispose_string(cString) }
        return String(cString: cString)
    }
}

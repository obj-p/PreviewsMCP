import Foundation
import PreviewsJITLinkCxx

public enum PreviewsJITLink {
    public static func mainDylibName() throws -> String {
        var name: UnsafeMutablePointer<CChar>?
        if let error = previewsmcp_jit_main_dylib_name(&name) {
            throw JITLinkError.failed(error.string())
        }
        guard let name else {
            throw JITLinkError.failed("no name returned")
        }
        return UnsafePointer(name).string()
    }

    public static func targetTriple() -> String {
        previewsmcp_jit_target_triple().string()
    }

    public static func linkAndCall<T>(objectPaths: [String], symbol: String) throws -> T {
        var raw: UInt64 = 0
        let error = objectPaths.withCStringArray { paths in
            previewsmcp_jit_link_and_call(paths, objectPaths.count, symbol, &raw)
        }
        if let error {
            throw JITLinkError.failed(error.string())
        }
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

private extension Array where Element == String {
    func withCStringArray<R>(_ body: (UnsafePointer<UnsafePointer<CChar>>) -> R) -> R {
        let cStrings: [UnsafeMutablePointer<CChar>] = map { strdup($0)! }
        defer { cStrings.forEach { free($0) } }
        let pointers: [UnsafePointer<CChar>] = cStrings.map { UnsafePointer($0) }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}

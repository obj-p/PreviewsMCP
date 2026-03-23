import Foundation

/// Loads a dynamic library and resolves symbols from it.
public final class DylibLoader: @unchecked Sendable {
    private let handle: UnsafeMutableRawPointer
    public let path: String

    /// Load a dylib at the given path.
    public init(path: String) throws {
        guard let handle = dlopen(path, RTLD_NOW | RTLD_GLOBAL) else {
            let error = String(cString: dlerror())
            throw DylibLoaderError.loadFailed(path: path, reason: error)
        }
        self.handle = handle
        self.path = path
    }

    /// Look up a C-callable symbol by name.
    public func symbol<T>(name: String, as type: T.Type = T.self) throws -> T {
        guard let sym = dlsym(handle, name) else {
            let error = String(cString: dlerror())
            throw DylibLoaderError.symbolNotFound(name: name, reason: error)
        }
        return unsafeBitCast(sym, to: T.self)
    }

    // Intentionally never dlclose — the loaded types may still be referenced
    // by SwiftUI views, AppKit views, or the Swift runtime metadata system.
    // Closing a dylib while its types are in use causes crashes.
}

public enum DylibLoaderError: Error, LocalizedError, CustomStringConvertible {
    case loadFailed(path: String, reason: String)
    case symbolNotFound(name: String, reason: String)

    public var description: String {
        switch self {
        case .loadFailed(let path, let reason):
            return "Failed to load dylib at \(path): \(reason)"
        case .symbolNotFound(let name, let reason):
            return "Symbol '\(name)' not found: \(reason)"
        }
    }

    public var errorDescription: String? { description }
}

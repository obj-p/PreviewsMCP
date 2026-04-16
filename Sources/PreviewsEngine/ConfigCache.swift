import Foundation
import PreviewsCore

/// Caches project config lookups by directory so repeated tool calls
/// against the same project don't hit the filesystem each time. One
/// instance is shared across all daemon connections.
public actor ConfigCache {
    private var cache: [String: ProjectConfigLoader.Result?] = [:]

    public init() {}

    public func load(for fileURL: URL) -> ProjectConfigLoader.Result? {
        let dir = fileURL.deletingLastPathComponent().standardizedFileURL.path
        if let cached = cache[dir] {
            return cached
        }
        let result = ProjectConfigLoader.find(from: fileURL.deletingLastPathComponent())
        cache[dir] = result
        return result
    }
}

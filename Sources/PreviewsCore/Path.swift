import Foundation

/// Namespace for path canonicalization helpers shared between the CLI,
/// daemon, and build-system modules.
public enum Path {

    /// Canonicalize a user-supplied path:
    /// 1. Expand a leading `~` or `~user` against the home directory.
    /// 2. Resolve relative paths against the current working directory.
    /// 3. Collapse `.` and `..` segments.
    /// 4. Resolve symlinks once.
    ///
    /// Returns an absolute, symlink-free, lexically normalized path string.
    /// Does not check existence — callers decide whether non-existent paths
    /// are valid for their use case (output paths often are; input paths are
    /// not).
    ///
    /// An empty input is returned unchanged so callers can detect "no path
    /// supplied" with the same string they passed in.
    public static func normalize(_ raw: String) -> String {
        if raw.isEmpty { return raw }
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return url.path
    }

    /// Canonicalize and return as a `URL`. Convenience around `normalize(_:)`
    /// for callers that need a URL — avoids re-wrapping the returned string
    /// in `URL(fileURLWithPath:)` and signals that no further canonicalization
    /// (`.standardizedFileURL`, `.resolvingSymlinksInPath()`) is needed.
    public static func normalizeURL(_ raw: String) -> URL {
        URL(fileURLWithPath: normalize(raw))
    }
}

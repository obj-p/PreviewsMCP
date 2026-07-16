import CryptoKit
import Foundation

/// Lazy fired-path content damping (docs/state-invalidation.md stage 4).
/// The first fire of a path records its content hash; a refire whose
/// content hashes to the recorded value is dropped, and a real change
/// updates the record. Normal sessions hash nothing until a burst
/// arrives, and only the burst's files ever. This makes a deterministic
/// in-tree generator (a build step rewriting a generated file with
/// identical content) converge after one refresh instead of looping.
struct FiredPathDamper {
    private var recorded: [String: String] = [:]

    /// Whether this fire represents a real change: true on first sight
    /// and on any content transition (including the path appearing or
    /// disappearing), false when the content hashes to the recorded
    /// value.
    mutating func isRealChange(_ path: String) -> Bool {
        let marker = Self.contentMarker(path)
        let previous = recorded.updateValue(marker, forKey: path)
        return previous != marker
    }

    private static func contentMarker(_ path: String) -> String {
        guard let data = FileManager.default.contents(atPath: path) else {
            return "absent"
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

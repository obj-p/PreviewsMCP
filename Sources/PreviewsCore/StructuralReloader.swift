import Foundation

/// Reloads a structurally-edited preview by linking a freshly compiled object in an
/// isolated process and running its render entry on that process's main thread. The
/// object's render entry writes the preview image to the path baked in at compile time
/// (file transport).
///
/// Defined here, JIT-free, so the daemon depends on this abstraction rather than the
/// gated JIT target: `PreviewsJITLink` provides the implementation and the executable
/// injects it only when the JIT build is present. The protocol is agnostic to whether
/// the implementation respawns a process per edit or reuses a capped-persistent one.
public protocol StructuralReloader: Sendable {
    /// Render `objectPath`'s entry, first linking any `archivePaths` (the target's
    /// dependency archives) and `supportObjectPaths` (the prebuilt stable-module objects
    /// from the recompile-narrowing split). Both are empty for the standalone path, where
    /// `objectPath` is self-contained.
    func renderObject(
        at objectPath: URL, supportObjectPaths: [URL], archivePaths: [URL], entrySymbol: String
    ) async throws
}

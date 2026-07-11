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
    /// Render `build`'s entry, first linking the target's dependencies: its `dylibPaths`
    /// (binary frameworks the agent `dlopen`s), `archivePaths` (static dependency archives),
    /// and `supportObjectPaths` (the prebuilt stable-module objects from the recompile-
    /// narrowing split). All are empty for the standalone path, where `objectPath` is
    /// self-contained.
    func render(_ build: JITRenderBuild) async throws

    /// Re-raster the live agent window to its image path by running `entrySymbol`
    /// (the generated `snapshotPreviewWindow`) on the live session's main thread, for a
    /// visible session's on-request snapshot (#346). The default is a no-op so reloaders with
    /// no live-window surface (and test stubs) need not implement it.
    func snapshotLiveWindow(entrySymbol: String) async throws
}

public extension StructuralReloader {
    func snapshotLiveWindow(entrySymbol _: String) async throws {}
}

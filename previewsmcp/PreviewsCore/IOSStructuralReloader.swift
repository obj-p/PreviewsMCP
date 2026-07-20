import Foundation

/// Daemon-side handle for the in-app iOS ORC executor reached over the EPC socket.
///
/// The iOS analogue of `StructuralReloader`: it links a freshly compiled object into
/// the live host app over the EPC connection and runs its render entry on the app's
/// main thread, which hosts the preview view on the key window. Unlike the macOS path
/// it does not raster a PNG; the daemon captures the simulator screen via `simctl`.
///
/// Defined here, JIT-free, so `IOSPreviewSession` can hold the connection without
/// depending on the gated JIT target: `PreviewsJITLink` provides the implementation and
/// the executable injects a factory only when the JIT build is present.
public protocol IOSStructuralReloader: Sendable {
    /// Link and render `build`'s entry over the EPC connection, first linking the target's
    /// dependency `dylibPaths` / `archivePaths` / `supportObjectPaths` (all empty for the
    /// standalone path, where `objectPath` is self-contained). A non-nil
    /// `progress` phases the setup and render entries; hot-reload paths
    /// pass nil and stay clock-free.
    func render(_ build: JITRenderBuild, progress: (any ProgressReporter)?) async throws
}

public extension IOSStructuralReloader {
    func render(_ build: JITRenderBuild) async throws {
        try await render(build, progress: nil)
    }
}

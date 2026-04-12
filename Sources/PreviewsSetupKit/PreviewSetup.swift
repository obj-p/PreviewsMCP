import SwiftUI

/// Conform to this protocol in a dedicated target to customize how PreviewsMCP
/// renders your previews. The setup target replaces micro apps / dev apps: it
/// provides the same mock dependency setup and theme wrapping, but PreviewsMCP
/// provides the app shell, hot-reload, and rendering infrastructure.
///
/// `setUp()` runs once when the host app launches — before any preview dylib is
/// loaded. It runs in a real UIApplication process (iOS) or NSApplication process
/// (macOS) with full app lifecycle. Use it for SDK initialization, authentication,
/// font registration, DI container setup, and mock service registration. It is
/// completely outside the hot-reload path.
///
/// `wrap(_:)` runs on every preview render (each structural recompile). Use it for
/// theme providers, custom environment values, and view-level setup that must
/// surround every preview.
///
/// Trait modifiers from `preview_configure` are applied outside this wrapper, so
/// explicit overrides always take precedence.
///
/// `AnyView` is required because the view type must be erased across the dynamic
/// library boundary.
public protocol PreviewSetup {
    /// Called once per session before the first preview renders.
    /// Async to support real auth flows and network calls.
    /// If this throws, the preview renders without setup and the error is
    /// reported as a warning to the MCP client.
    static func setUp() async throws

    /// Wraps every preview view. Called on each dylib load.
    static func wrap(_ content: AnyView) -> AnyView
}

extension PreviewSetup {
    public static func setUp() async throws {}
    public static func wrap(_ content: AnyView) -> AnyView { content }
}

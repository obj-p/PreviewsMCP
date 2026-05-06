/// Swift source code for `__PreviewBridge.wrap(_:)`, compiled into every preview dylib.
///
/// This is a source template, not code compiled as part of `PreviewsCore`. The template
/// is embedded into the generated bridge source so that `#Preview` blocks can return
/// SwiftUI views, UIKit `UIView`s, or UIKit `UIViewController`s — matching Xcode's own
/// `#Preview` macro surface.
///
/// The helper is exposed as `code(for: platform)` rather than a single `static let code`
/// (cf. `DesignTimeStoreSource`) because the emitted overload set is platform-specific
/// and platform cannot be inferred from the compiler's `#if canImport(UIKit)`: UIKit is
/// available on macOS SDKs for Catalyst interop, so it would compile in on macOS-only
/// builds where we don't want it. The `PreviewPlatform` value passed to the generator
/// is the authoritative source of truth.
public enum PreviewBridgeSource {
    /// Swift source for the `__PreviewBridge.wrap(_:)` helper, specialized for the given platform.
    ///
    /// - iOS emission: SwiftUI generic overload + UIView / UIViewController overloads wrapped
    ///   in SwiftUI representables.
    /// - macOS emission: SwiftUI generic overload only. AppKit bodies (NSView / NSViewController)
    ///   are out of scope for now.
    public static func code(for platform: PreviewPlatform) -> String {
        switch platform {
        case .iOS:
            return iOSCode
        case .macOS:
            return macOSCode
        }
    }

    private static let macOSCode = """
        import SwiftUI

        enum __PreviewBridge {
            // Intentionally nonisolated: the generated `@_cdecl` entry point is synchronous
            // and nonisolated, matching the nested-function form this helper replaces. The
            // actual call is made on the main thread by the dylib loader; static isolation
            // would require propagating @MainActor across the @_cdecl boundary.
            static func wrap<V: SwiftUI.View>(@SwiftUI.ViewBuilder _ body: () -> V) -> SwiftUI.AnyView {
                SwiftUI.AnyView(body())
            }
        }

        // macOS bridge has no UIKit overloads, so the body is always SwiftUI.
        // 1 = swiftUI, 2 = uiView, 3 = uiViewController. Returned via @_cdecl
        // so the daemon can read the kind without reflecting on AnyView internals.
        enum __PreviewBodyKindProbe {
            static func detect<V: SwiftUI.View>(@SwiftUI.ViewBuilder _ body: () -> V) -> Int32 { 1 }
        }
        """

    private static let iOSCode = """
        import SwiftUI
        import UIKit

        enum __PreviewBridge {
            // See macOS comment above — intentionally nonisolated.
            static func wrap<V: SwiftUI.View>(@SwiftUI.ViewBuilder _ body: () -> V) -> SwiftUI.AnyView {
                SwiftUI.AnyView(body())
            }
            // UIKit bodies are auto-wrapped in a SwiftUI representable, matching Xcode's #Preview.
            // Multi-statement UIKit bodies need an explicit `return` (no @ViewBuilder equivalent in UIKit).
            static func wrap(_ body: () -> UIKit.UIView) -> SwiftUI.AnyView {
                SwiftUI.AnyView(__PreviewUIViewBridge(view: body()))
            }
            static func wrap(_ body: () -> UIKit.UIViewController) -> SwiftUI.AnyView {
                SwiftUI.AnyView(__PreviewUIViewControllerBridge(controller: body()))
            }
        }

        // Mirror of `__PreviewBridge.wrap`'s overload set. The compiler resolves the same
        // overload that `wrap` does, so the daemon learns the outermost body kind without
        // a separate type-checker pass — used to skip the literal-only fast path for UIKit
        // bodies, where mutating DesignTimeStore values doesn't drive a re-render (#160).
        // 1 = swiftUI, 2 = uiView, 3 = uiViewController.
        enum __PreviewBodyKindProbe {
            static func detect<V: SwiftUI.View>(@SwiftUI.ViewBuilder _ body: () -> V) -> Int32 { 1 }
            static func detect(_ body: () -> UIKit.UIView) -> Int32 { 2 }
            static func detect(_ body: () -> UIKit.UIViewController) -> Int32 { 3 }
        }

        private struct __PreviewUIViewBridge: SwiftUI.UIViewRepresentable {
            let view: UIKit.UIView
            func makeUIView(context: Context) -> UIKit.UIView { view }
            func updateUIView(_ uiView: UIKit.UIView, context: Context) {}
        }

        private struct __PreviewUIViewControllerBridge: SwiftUI.UIViewControllerRepresentable {
            let controller: UIKit.UIViewController
            func makeUIViewController(context: Context) -> UIKit.UIViewController { controller }
            func updateUIViewController(_ uiViewController: UIKit.UIViewController, context: Context) {}
        }
        """
}

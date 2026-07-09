import Foundation

/// Placement and size for the agent's preview window, baked into the render entry. The size is
/// always honored; `headless` selects presentation: a visible titled window placed at `x`/`y`,
/// or a borderless off-screen window used only to render at the requested size (snapshots,
/// headless daemons). Applied only when the agent creates the window, so a user's later drag or
/// resize survives leaf edits. Nil means no spec at all — a borderless off-screen default size.
/// `activate` selects whether a visible window takes key status and activates the app on
/// creation: true for a session's first window, and on a respawn handoff only when the outgoing
/// window was key — so an edit never steals focus from whatever the user was typing in (#254).
public struct JITRenderWindow: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let title: String
    public let headless: Bool
    public let activate: Bool

    public init(
        x: Double, y: Double, width: Double, height: Double, title: String,
        headless: Bool = false, activate: Bool = true
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.title = title
        self.headless = headless
        self.activate = activate
    }
}

/// Generates Swift source code that combines the original source file with a `@_cdecl` bridge
/// entry point, allowing the preview view to be loaded via `dlopen` + `dlsym`.
public enum BridgeGenerator {
    /// Generate combined source with DesignTimeStore + literal thunks + bridge entry point.
    ///
    /// - Parameters:
    ///   - originalSource: The full content of the original Swift source file.
    ///   - closureBody: The body of the `#Preview { ... }` closure from the original source.
    ///     Used as fallback if re-parsing the transformed source yields fewer previews than expected.
    ///   - previewIndex: 0-based index of which `#Preview` block to render (default: 0).
    /// - Returns: Tuple of (source code ready to compile, literal entries for diffing).
    public static func generateCombinedSource(
        originalSource: String,
        closureBody: String,
        previewIndex: Int = 0,
        platform: PreviewPlatform = .macOS,
        traits: PreviewTraits = PreviewTraits(),
        setupModule: String? = nil,
        setupType: String? = nil,
        renderOutputPath: String? = nil,
        designTimeValuesPath: String? = nil,
        stableModuleImport: String? = nil,
        renderWindow: JITRenderWindow? = nil,
        frameSidecarPath: String? = nil
    ) -> (source: String, literals: [LiteralEntry]) {
        // Transform source to replace literals with DesignTimeStore lookups
        let thunkResult = ThunkGenerator.transform(source: originalSource)

        // Re-parse transformed source to get the closure body with DesignTimeStore calls
        let previews = PreviewParser.parse(source: thunkResult.source)
        let transformedClosureBody: String = if previewIndex < previews.count {
            previews[previewIndex].closureBody
        } else {
            closureBody
        }

        let modifiers = traitModifiers(traits)
        let hasSetup = isUsableSetup(module: setupModule, type: setupType)
        let setupImport = hasSetup ? "import \(setupModule!)\n" : ""
        let setUpEntry = hasSetup ? setUpEntryPoint(setupType: setupType!) : ""
        let viewCode =
            hasSetup
                ? viewWithSetup(closureBody: transformedClosureBody, setupType: setupType!, modifiers: modifiers)
                : """
                {
                            return SwiftUI.AnyView(__PreviewBridge.wrap {
                                \(transformedClosureBody)
                            }\(modifiers))
                        }()
                """

        let renderEntry =
            renderOutputPath.map { path -> String in
                switch platform {
                case .macOS:
                    return renderToFileEntryPoint(
                        viewCode: viewCode, path: path, valuesPath: designTimeValuesPath,
                        window: renderWindow, frameSidecarPath: frameSidecarPath
                    )
                case .iOS:
                    return iosRenderEntryPoint(viewCode: viewCode, valuesPath: designTimeValuesPath)
                }
            } ?? ""
        let bridgeCode = switch platform {
        case .macOS:
            """
            import AppKit
            \(setupImport)
            \(setUpEntry)
            \(renderEntry)
            """
        case .iOS:
            """
            import UIKit
            \(setupImport)
            \(setUpEntry)
            \(renderEntry)
            """
        }

        let stableImport =
            stableModuleImport.map { "@testable import \($0)\n" } ?? ""
        let combined = """
        \(stableImport)// --- DesignTimeStore ---
        \(DesignTimeStoreSource.code)

        // --- Preview bridge helper (generated by PreviewsMCP) ---
        \(PreviewBridgeSource.code(for: platform))

        // --- Source (with literal thunks) ---
        \(thunkResult.source)

        // --- Preview bridge (generated by PreviewsMCP) ---
        \(bridgeCode)
        """

        return (source: combined, literals: thunkResult.literals)
    }

    // MARK: - __PreviewBridge.wrap

    //
    // The generated bridge passes the user's closure body to
    // `__PreviewBridge.wrap { <body> }` (declared in `PreviewBridgeSource`),
    // which dispatches through Swift overload resolution:
    //
    //   - SwiftUI bodies (any `V: SwiftUI.View`) match a `@ViewBuilder` generic
    //     overload — preserving every construct Xcode's `#Preview` accepts:
    //     `if #available`, leading `let`/`var` declarations, branches with
    //     different concrete types, etc. The `@ViewBuilder` attribute lifts
    //     statement-only restrictions via `_ConditionalContent`.
    //   - UIKit bodies (`UIView`, `UIViewController`, and their subclasses)
    //     match dedicated non-generic overloads that wrap the view in a
    //     `UIViewRepresentable` / `UIViewControllerRepresentable` bridge —
    //     matching what Xcode's `#Preview` macro does for UIKit bodies.
    //
    // This replaces an earlier design that declared a nested
    // `@ViewBuilder func __previewBody() -> some SwiftUI.View { <body> }`,
    // which rejected UIKit bodies with
    // "'ExampleUIView' does not conform to 'View'".
    //
    // Caveat: UIKit has no `@ViewBuilder` equivalent, so multi-statement
    // UIKit bodies require an explicit `return`. Same constraint applies to
    // Xcode's first-party `#Preview` macro for UIKit.

    /// Validate that a string is safe to interpolate as a Swift identifier or dotted module path.
    private static func isValidSwiftIdentifier(_ s: String) -> Bool {
        let pattern = #"^[A-Za-z_][A-Za-z0-9_]*(\.[A-Za-z_][A-Za-z0-9_]*)*$"#
        return s.range(of: pattern, options: .regularExpression) != nil
    }

    /// Whether a setup module/type pair will actually produce setup code (the wrap and the
    /// `previewSetUp` entry). Callers that advertise setup downstream (e.g. a build's
    /// setupEntrySymbol) must use the same predicate, or they promise an entry the generated
    /// source does not contain.
    public static func isUsableSetup(module: String?, type: String?) -> Bool {
        guard let module, let type else { return false }
        return isValidSwiftIdentifier(module) && isValidSwiftIdentifier(type)
    }

    /// Escape a runtime string (path, window title) for interpolation into a generated Swift
    /// string literal. Backslash and quote would change the literal's structure; control
    /// characters (a newline in a file name is legal on macOS) would split it across lines.
    static func escapedForSwiftStringLiteral(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case let c where c.properties.generalCategory == .control:
                out += "\\u{\(String(c.value, radix: 16))}"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }

    /// Generated code (run at the top of a render entry) that re-seeds `DesignTimeStore`
    /// from the values JSON the daemon rewrites per literal edit. Empty when no path.
    private static func designTimeSeed(_ valuesPath: String?) -> String {
        valuesPath.map {
            """
            if let __dtData = try? Data(contentsOf: URL(fileURLWithPath: "\(escapedForSwiftStringLiteral($0))")),
                let __dtValues = try? JSONSerialization.jsonObject(with: __dtData)
                    as? [String: Any]
            {
                DesignTimeStore.shared.values = __dtValues
            }
            """
        } ?? ""
    }

    /// Generate the `@_cdecl("renderPreviewToFile")` entry point (macOS, model-A JIT path).
    /// Builds the same preview view as `createPreviewView`, hosts it in a borderless
    /// `NSWindow` positioned off-screen via `NSHostingView` (AppKit-backed views like
    /// `List` need a real window's backing hierarchy — `ImageRenderer` returns nil or a
    /// blank raster for them), captures at a deterministic 1x,
    /// and writes a PNG to `path`. Nullary so it runs over the agent's `runOnMain`
    /// surface; the path is baked in (the daemon recompiles per structural edit).
    ///
    /// The window is process-persistent: each generation's entry looks it up by
    /// identifier in the agent's window list and swaps its content view, so the agent
    /// keeps one live window across structural edits (single-renderer consolidation).
    /// AppKit state is shared across JITDylib generations; the entry's own globals are not.
    private static func renderToFileEntryPoint(
        viewCode: String, path: String, valuesPath: String?, window: JITRenderWindow?,
        frameSidecarPath: String?
    ) -> String {
        let seed = designTimeSeed(valuesPath)
        let createWindow: String
        let presentNewWindow: String
        let frameObservers: String
        let firstFrameFlush: String
        if let window, !window.headless {
            let title = escapedForSwiftStringLiteral(window.title)
            createWindow = """
            NSApplication.shared.setActivationPolicy(.accessory)
                            let created = NSWindow(
                                contentRect: NSRect(
                                    x: \(window.x), y: \(window.y),
                                    width: \(window.width), height: \(window.height)),
                                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                backing: .buffered, defer: false)
                            created.title = "\(title)"
                            created.animationBehavior = .none
            """
            // A visible window takes key status and activates the agent only when the spec
            // asks (a session's first window, or a handoff replacing the key window).
            // Re-renders and non-key handoffs use orderFrontRegardless so edits never
            // steal focus.
            presentNewWindow = window.activate
                ? """
                window.makeKeyAndOrderFront(nil)
                                NSApplication.shared.activate(ignoringOtherApps: true)
                """
                : "window.orderFrontRegardless()"
            frameObservers = frameSidecarPath.map(frameObserverCode) ?? ""
            // The synchronous entry return is the daemon's handoff-ready signal: the old
            // agent (and its window) dies right after. Push the first frame to the
            // WindowServer before returning so the overlap never shows a blank window.
            firstFrameFlush = """
            if isNewWindow {
                                window.displayIfNeeded()
                                CATransaction.flush()
                            }
            """
        } else {
            // Headless spec or no spec: a borderless off-screen window used only to render at
            // the requested size, never shown or activated. Falls back to 400x600 with no spec.
            let offscreenWidth = window?.width.description ?? "400"
            let offscreenHeight = window?.height.description ?? "600"
            createWindow = """
            let created = NSWindow(
                                contentRect: NSRect(x: 0, y: 0, width: \(offscreenWidth), height: \(offscreenHeight)),
                                styleMask: [.borderless], backing: .buffered, defer: false)
                            created.setFrameOrigin(NSPoint(x: -10_000, y: -10_000))
            """
            presentNewWindow = "window.orderFrontRegardless()"
            frameObservers = ""
            firstFrameFlush = ""
        }
        return """
        @_cdecl("renderPreviewToFile")
        public func renderPreviewToFile() -> Int32 {
            MainActor.assumeIsolated {
                \(seed)
                let view = \(viewCode)
                let identifier = NSUserInterfaceItemIdentifier("previewsmcp-preview")
                var isNewWindow = false
                let window =
                    NSApplication.shared.windows.first { $0.identifier == identifier }
                    ?? {
                        \(createWindow)
                        created.identifier = identifier
                        created.isReleasedWhenClosed = false
                        isNewWindow = true
                        return created
                    }()
                let hosting = NSHostingView(rootView: view)
                hosting.sizingOptions = []
                window.contentView = hosting
                if isNewWindow {
                    \(presentNewWindow)
                    \(frameObservers)
                } else {
                    window.orderFrontRegardless()
                }
                hosting.layoutSubtreeIfNeeded()
                \(firstFrameFlush)
                let bounds = hosting.bounds
                guard bounds.width > 0, bounds.height > 0,
                    let rep = NSBitmapImageRep(
                        bitmapDataPlanes: nil,
                        pixelsWide: Int(bounds.width.rounded()),
                        pixelsHigh: Int(bounds.height.rounded()),
                        bitsPerSample: 8,
                        samplesPerPixel: 4,
                        hasAlpha: true,
                        isPlanar: false,
                        colorSpaceName: .deviceRGB,
                        bytesPerRow: 0,
                        bitsPerPixel: 0
                    )
                else { return Int32(-1) }
                rep.size = bounds.size
                hosting.cacheDisplay(in: bounds, to: rep)
                guard let data = rep.representation(using: .png, properties: [:]) else {
                    return Int32(-2)
                }
                do {
                    try data.write(to: URL(fileURLWithPath: "\(escapedForSwiftStringLiteral(path))"))
                } catch {
                    return Int32(-3)
                }
                return 0
            }
        }
        """
    }

    /// Generate the `@_cdecl("renderPreviewToFile")` entry point (iOS JIT path). Builds the
    /// same preview view as `createPreviewView`, hosts it in a `UIHostingController`, and sets
    /// it as the live host app's key-window `rootViewController` on the main actor. Unlike the
    /// macOS entry it does not raster a PNG: the daemon captures the simulator screen via
    /// `simctl`, so the baked render path is unused here. Nullary and run over the agent's
    /// `runOnMain` surface; re-running it after a literal edit re-seeds DesignTimeStore.
    private static func iosRenderEntryPoint(viewCode: String, valuesPath: String?) -> String {
        let seed = designTimeSeed(valuesPath)
        return """
        @_silgen_name("previewsmcp_set_preview_vc")
        func _previewsmcp_set_preview_vc(_ pointer: UnsafeRawPointer)

        @_cdecl("renderPreviewToFile")
        public func renderPreviewToFile() -> Int32 {
            MainActor.assumeIsolated {
                \(seed)
                let view = \(viewCode)
                let hosting = UIHostingController(rootView: view)
                _previewsmcp_set_preview_vc(Unmanaged.passRetained(hosting).toOpaque())
                return 0
            }
        }
        """
    }

    /// Code (run once when the agent creates its visible window) that records the window's frame
    /// and key status to `sidecarPath` on every move/resize/key change. A respawned agent reads
    /// it back so the user's dragged/resized window is restored across non-leaf structural edits
    /// (#195) and the handoff replacement only takes key when the outgoing window had it (#254).
    /// Reads the state off the notification's window so the `@Sendable` observer closure captures
    /// only the path.
    private static func frameObserverCode(sidecarPath: String) -> String {
        """
        let __frameURL = URL(fileURLWithPath: "\(escapedForSwiftStringLiteral(sidecarPath))")
                        let __recordFrame: @Sendable (Notification) -> Void = { __note in
                            MainActor.assumeIsolated {
                                guard let __win = __note.object as? NSWindow else { return }
                                let __f = __win.frame
                                let __dict: [String: Any] = [
                                    "x": __f.origin.x, "y": __f.origin.y,
                                    "width": __f.size.width, "height": __f.size.height,
                                    "key": __win.isKeyWindow,
                                ]
                                if let __data = try? JSONSerialization.data(withJSONObject: __dict) {
                                    try? __data.write(to: __frameURL, options: .atomic)
                                }
                            }
                        }
                        for __name in [
                            NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                            NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                        ] {
                            NotificationCenter.default.addObserver(
                                forName: __name, object: window, queue: nil, using: __recordFrame)
                        }
        """
    }

    /// Generate the `@_cdecl("previewSetUp")` entry point that bridges async setUp.
    private static func setUpEntryPoint(setupType: String) -> String {
        """
        @_cdecl("previewSetUp")
        public func previewSetUp() {
            let semaphore = DispatchSemaphore(value: 0)
            Task {
                try? await \(setupType).setUp()
                semaphore.signal()
            }
            semaphore.wait()
        }
        """
    }

    /// Generate view code with setup wrapping. The closure body is threaded through
    /// `__PreviewBridge.wrap` (which dispatches to SwiftUI / UIKit overloads via overload
    /// resolution) before being handed to the setup plugin's `wrap`. Traits are applied
    /// OUTSIDE the setup wrap so explicit overrides take precedence.
    private static func viewWithSetup(closureBody: String, setupType: String, modifiers: String) -> String {
        """
        {
                let innerView = __PreviewBridge.wrap {
                    \(closureBody)
                }
                let wrappedView = \(setupType).wrap(innerView)
                return SwiftUI.AnyView(
                    wrappedView\(modifiers)
                )
            }()
        """
    }

    /// Build SwiftUI modifier chain for the given traits.
    private static func traitModifiers(_ traits: PreviewTraits) -> String {
        var mods = ""
        if let cs = traits.colorScheme {
            mods += "\n            .preferredColorScheme(.\(cs))"
        }
        if let dts = traits.dynamicTypeSize {
            mods += "\n            .dynamicTypeSize(.\(dts))"
        }
        if let locale = traits.locale {
            mods += "\n            .environment(\\.locale, Locale(identifier: \"\(locale)\"))"
        }
        if let ld = traits.layoutDirection {
            mods += "\n            .environment(\\.layoutDirection, .\(ld))"
        }
        if let lw = traits.legibilityWeight {
            mods += "\n            .environment(\\.legibilityWeight, .\(lw))"
        }
        return mods
    }
}

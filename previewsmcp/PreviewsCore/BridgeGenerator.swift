import Foundation

/// Placement and size for the agent's preview window, baked into the render entry. The size is
/// always honored; `headless` selects presentation: a visible titled window placed at `x`/`y`,
/// or a borderless off-screen window used only to render at the requested size (snapshots,
/// headless daemons). Applied only when the agent creates the window, so a user's later drag or
/// resize survives leaf edits. Nil means no spec at all — a borderless off-screen default size.
/// Whether a new visible window takes key status is not baked: the generated entry decides at
/// render time from the sidecar's live key record, so a focus change during the compile never
/// steals or drops focus (#254). `activates: false` opts a visible window out of that decision
/// entirely — it is presented with `orderFrontRegardless()` and never takes key or activates
/// the app, for callers that need a real on-screen window without stealing focus (#358).
public struct JITRenderWindow: Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double
    public let title: String
    public let headless: Bool
    public let activates: Bool

    public init(
        x: Double, y: Double, width: Double, height: Double, title: String,
        headless: Bool = false, activates: Bool = true
    ) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
        self.title = title
        self.headless = headless
        self.activates = activates
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
        let preRasterPresent: String
        let postRasterPresent: String
        let stateWriter: String
        let snapshotWriter: String
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
            // A new visible window is presented only after the raster succeeds, so a
            // failing render never flashes a half-built window over the previous
            // generation (the daemon keeps the old agent alive on failure). It takes key
            // and activates only when the sidecar's live record says the outgoing window
            // was key at this instant — decided at render time, not compile time, so a
            // focus change during the compile never steals or drops focus. A spec with
            // `activates: false` skips that decision and never takes key or activates
            // the app (#358). The trailing flush pushes the first frame to the
            // WindowServer before the entry returns, because that return is the
            // daemon's kill-the-old-agent signal.
            preRasterPresent = """
            if !isNewWindow {
                                window.orderFrontRegardless()
                            }
            """
            let firstPresent =
                window.activates
                    ? """
                    \(frameSidecarPath.map(runtimeKeyDecisionCode) ?? "let __takeKey = true")
                                    if __takeKey {
                                        window.makeKeyAndOrderFront(nil)
                                        NSApplication.shared.activate(ignoringOtherApps: true)
                                    } else {
                                        window.orderFrontRegardless()
                                    }
                    """
                    : "window.orderFrontRegardless()"
            postRasterPresent = """
            if isNewWindow {
                                \(firstPresent)
                                \(frameSidecarPath != nil ? frameObserverCode() : "")
                                \(frameSidecarPath != nil ? "__previewsmcpWriteWindowState(window)" : "")
                                window.displayIfNeeded()
                                CATransaction.flush()
                            }
            """
            stateWriter = frameSidecarPath.map(windowStateWriterCode) ?? ""
            snapshotWriter = snapshotEntryCode(path: path)
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
            preRasterPresent = """
            window.orderFrontRegardless()
                            _ = isNewWindow
            """
            postRasterPresent = ""
            stateWriter = ""
            snapshotWriter = ""
        }
        return """
        \(rasterHelperCode())
        \(stateWriter)
        \(snapshotWriter)
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
                \(preRasterPresent)
                let __rc = __previewsmcpRasterView(
                    hosting, to: "\(escapedForSwiftStringLiteral(path))")
                guard __rc == 0 else { return __rc }
                \(postRasterPresent)
                return 0
            }
        }
        """
    }

    /// Top-level helper (macOS render + live-snapshot entries) that rasters a view's current
    /// content to a PNG at `path` via `cacheDisplay`, writing atomically so a failed write
    /// leaves the previous image intact for a caller to fall back on. Emitting one helper keeps
    /// the render-time PNG and the on-request live snapshot pixel-identical (#346): both go
    /// through the same pixel format, color space, 1x point sizing, and PNG encoding. Status:
    /// 0 ok, -2 zero bounds / bitmap alloc, -3 PNG encode, -4 write.
    private static func rasterHelperCode() -> String {
        """
        @MainActor
        func __previewsmcpRasterView(_ __view: NSView, to __path: String) -> Int32 {
            __view.layoutSubtreeIfNeeded()
            let __bounds = __view.bounds
            guard __bounds.width > 0, __bounds.height > 0,
                let __rep = NSBitmapImageRep(
                    bitmapDataPlanes: nil,
                    pixelsWide: Int(__bounds.width.rounded()),
                    pixelsHigh: Int(__bounds.height.rounded()),
                    bitsPerSample: 8,
                    samplesPerPixel: 4,
                    hasAlpha: true,
                    isPlanar: false,
                    colorSpaceName: .deviceRGB,
                    bytesPerRow: 0,
                    bitsPerPixel: 0
                )
            else { return Int32(-2) }
            __rep.size = __bounds.size
            __view.cacheDisplay(in: __bounds, to: __rep)
            guard let __data = __rep.representation(using: .png, properties: [:]) else {
                return Int32(-3)
            }
            do {
                try __data.write(to: URL(fileURLWithPath: __path), options: .atomic)
            } catch {
                return Int32(-4)
            }
            return 0
        }
        """
    }

    /// Top-level helper (visible windows with a sidecar) that atomically records the window's
    /// content rect and key status. Called by the frame/key observers, once at first
    /// presentation, and by the `recordPreviewWindowState` entry the reloader runs after a
    /// handoff kills the outgoing agent — the last write is then guaranteed to describe the
    /// surviving window, without the daemon ever writing the sidecar itself.
    private static func windowStateWriterCode(sidecarPath: String) -> String {
        """
        @MainActor
        func __previewsmcpWriteWindowState(_ __win: NSWindow) {
            let __f = __win.contentRect(forFrameRect: __win.frame)
            let __dict: [String: Any] = [
                "x": __f.origin.x, "y": __f.origin.y,
                "width": __f.size.width, "height": __f.size.height,
                "key": __win.isKeyWindow,
            ]
            if let __data = try? JSONSerialization.data(withJSONObject: __dict) {
                try? __data.write(
                    to: URL(fileURLWithPath: "\(escapedForSwiftStringLiteral(sidecarPath))"),
                    options: .atomic)
            }
        }

        @_cdecl("recordPreviewWindowState")
        public func recordPreviewWindowState() -> Int32 {
            MainActor.assumeIsolated {
                let identifier = NSUserInterfaceItemIdentifier("previewsmcp-preview")
                guard
                    let window = NSApplication.shared.windows.first(where: {
                        $0.identifier == identifier
                    })
                else { return Int32(-1) }
                __previewsmcpWriteWindowState(window)
                return 0
            }
        }
        """
    }

    /// Top-level entry (visible windows) that re-rasters the live preview window's current
    /// content view to the baked image path — without rebuilding the view or touching window
    /// placement. The daemon runs it over `runOnMain` when `preview_snapshot` targets a visible
    /// session, so the returned image reflects post-render interaction (toggles, scrolls, typed
    /// text) that the render-time PNG cannot contain (#346). `cacheDisplay` re-renders the view
    /// hierarchy into a bitmap rather than screenshotting the display, so it works even when the
    /// window is occluded or not key.
    private static func snapshotEntryCode(path: String) -> String {
        """
        @_cdecl("snapshotPreviewWindow")
        public func snapshotPreviewWindow() -> Int32 {
            MainActor.assumeIsolated {
                let identifier = NSUserInterfaceItemIdentifier("previewsmcp-preview")
                guard
                    let window = NSApplication.shared.windows.first(where: {
                        $0.identifier == identifier
                    }),
                    let hosting = window.contentView
                else { return Int32(-1) }
                return __previewsmcpRasterView(
                    hosting, to: "\(escapedForSwiftStringLiteral(path))")
            }
        }
        """
    }

    /// Reads the sidecar's live key record to decide whether the replacement window takes key.
    /// Absent sidecar or key field means the window never reported otherwise: take key,
    /// matching a session's first visible window.
    private static func runtimeKeyDecisionCode(sidecarPath: String) -> String {
        """
        var __takeKey = true
                            if let __data = try? Data(
                                contentsOf: URL(fileURLWithPath: "\(escapedForSwiftStringLiteral(sidecarPath))")),
                                let __obj = try? JSONSerialization.jsonObject(with: __data) as? [String: Any],
                                let __key = __obj["key"] as? Bool
                            {
                                __takeKey = __key
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

    /// Code (run once when the agent creates its visible window) that records the window's
    /// state via `__previewsmcpWriteWindowState` on every move/resize/key change. A respawned
    /// agent reads it back so the user's dragged/resized window is restored across non-leaf
    /// structural edits (#195) and the handoff replacement only takes key when the outgoing
    /// window had it (#254). The content rect (not the frame) is recorded because that is what
    /// window creation bakes, so readers never need the window's style mask.
    private static func frameObserverCode() -> String {
        """
        for __name in [
                                NSWindow.didMoveNotification, NSWindow.didResizeNotification,
                                NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                            ] {
                                NotificationCenter.default.addObserver(
                                    forName: __name, object: window, queue: nil
                                ) { __note in
                                    // NSWindow notifications fire on main (hence
                                    // assumeIsolated); the unsafe binding keeps the
                                    // non-Sendable payload legal when the target's
                                    // captured language mode is Swift 6.
                                    nonisolated(unsafe) let __object = __note.object
                                    MainActor.assumeIsolated {
                                        guard let __win = __object as? NSWindow else { return }
                                        __previewsmcpWriteWindowState(__win)
                                    }
                                }
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

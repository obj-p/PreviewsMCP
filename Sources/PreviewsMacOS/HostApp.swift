import AppKit
import PreviewsCore
import SwiftUI

/// Manages preview windows. Loads compiled dylibs and displays views in NSWindows.
///
/// Only one runtime shape remains since the CLI/MCP parity migration:
/// `serve` is the sole subcommand that ever constructs a PreviewHost, and
/// it always wants headless windows plus a daemon that stays alive after
/// the last window closes. Earlier `.interactive` and `.snapshot` modes
/// were removed once every non-`serve` CLI command moved to the daemon
/// client path.
@MainActor
public class PreviewHost: NSObject, NSApplicationDelegate {

    private var windows: [String: NSWindow] = [:]
    private var loaders: [String: DylibLoader] = [:]
    private var sessions: [String: PreviewSession] = [:]
    // Keep old loaders and views alive so their dylib types remain valid.
    private var retainedLoaders: [DylibLoader] = []
    private var retainedViews: [NSView] = []
    private var hasCalledSetUp = false
    /// Retains the setup dylib loaded with RTLD_GLOBAL so all preview dylibs share its statics.
    private var setupDylibLoader: DylibLoader?
    /// Remembered so the watchFile reload path can pass it to loadPreview.
    private var setupDylibPath: URL?

    /// Callback invoked after NSApplication finishes launching.
    public var onLaunch: (@MainActor () -> Void)?

    public override init() {
        super.init()
    }

    /// Windows are positioned off-screen with no Dock icon.
    public let headless: Bool = true

    private var fileWatchers: [String: FileWatcher] = [:]
    private var retainedFileWatchers: [FileWatcher] = []

    /// Hold a strong reference to a file watcher for the lifetime of the
    /// host. `FileWatcher`'s timer closure captures `self` weakly, so a
    /// watcher goes silent as soon as the creating scope releases its
    /// local binding. The macOS preview path stores its watchers in the
    /// keyed `fileWatchers` map (cleaned up per-session); the iOS `run`
    /// path has no such per-session cleanup and uses this bag instead.
    public func retainFileWatcher(_ watcher: FileWatcher) {
        retainedFileWatchers.append(watcher)
    }

    public func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // The daemon must stay alive after all preview windows close so
        // it can accept new session requests without a cold restart.
        return false
    }

    /// Load a dylib and display its preview view in a window.
    /// If a window already exists for this session, reuses it (swaps content view).
    /// - Parameter headless: If provided, overrides the instance-level default for this window.
    /// - Parameter setupDylibPath: Path to the setup dynamic library. Loaded once with RTLD_GLOBAL
    ///   so all preview dylibs share the same statics (see issue #86).
    public func loadPreview(
        sessionID: String,
        dylibPath: URL,
        entryPoint: String = "createPreviewView",
        title: String = "Preview",
        size: NSSize = NSSize(width: 400, height: 600),
        headless: Bool? = nil,
        setupDylibPath: URL? = nil
    ) throws {
        let headless = headless ?? self.headless

        // Load the setup dylib once before any preview dylib. RTLD_GLOBAL ensures
        // all preview dylibs resolve setup symbols from this shared image.
        if let path = setupDylibPath {
            self.setupDylibPath = path
        }
        if let path = self.setupDylibPath, setupDylibLoader == nil {
            setupDylibLoader = try DylibLoader(path: path.path)
        }

        let loader = try DylibLoader(path: dylibPath.path)

        // Call setUp exactly once on first dylib load
        if !hasCalledSetUp {
            hasCalledSetUp = true
            typealias SetUpFunc = @convention(c) () -> Void
            if let setUpFn: SetUpFunc = try? loader.symbol(name: "previewSetUp") {
                setUpFn()
            }
        }

        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let createView: CreateFunc = try loader.symbol(name: entryPoint)

        // Retire the old loader (keep it alive, don't dlclose)
        if let oldLoader = loaders.removeValue(forKey: sessionID) {
            retainedLoaders.append(oldLoader)
        }
        loaders[sessionID] = loader

        // Create the view
        let rawPtr = createView()
        let hostingView = Unmanaged<NSView>.fromOpaque(rawPtr).takeRetainedValue()

        if let existingWindow = windows[sessionID] {
            // Retain old content view before swapping
            if let oldView = existingWindow.contentView {
                retainedViews.append(oldView)
            }
            existingWindow.contentView = hostingView
            existingWindow.title = title
        } else {
            // Create new window
            let window = NSWindow(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: headless
                    ? .borderless : [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.contentView = hostingView
            if headless {
                window.setFrameOrigin(NSPoint(x: -10000, y: -10000))
                window.orderFrontRegardless()
            } else {
                window.center()
                window.makeKeyAndOrderFront(nil)
                NSApp.setActivationPolicy(.regular)
                NSApp.activate(ignoringOtherApps: true)
            }
            windows[sessionID] = window
        }
    }

    /// Start watching source files and reload the preview on changes.
    /// Uses the fast path (literal-only update via DesignTimeStore) when possible.
    /// When `additionalPaths` is provided, watches all target files for cross-file changes.
    public func watchFile(
        sessionID: String,
        session: PreviewSession,
        filePath: String,
        compiler: Compiler,
        additionalPaths: [String] = [],
        buildContext: BuildContext? = nil
    ) {
        sessions[sessionID] = session
        let fileURL = URL(fileURLWithPath: filePath)
        let allPaths = [filePath] + additionalPaths
        fileWatchers[sessionID]?.stop()
        fileWatchers[sessionID] = try? FileWatcher(paths: allPaths) { [weak self] in
            Task {
                guard let self else { return }

                let newSource: String
                do {
                    newSource = try String(contentsOf: fileURL, encoding: .utf8)
                } catch {
                    fputs("Failed to read file: \(error)\n", stderr)
                    return
                }

                // Fast path: try literal-only update
                if let currentSession = await MainActor.run(body: { self.sessions[sessionID] }),
                    let changes = await currentSession.tryLiteralUpdate(newSource: newSource),
                    !changes.isEmpty
                {
                    fputs("Literal-only change: \(changes.count) value(s)\n", stderr)
                    await MainActor.run {
                        self.applyLiteralChanges(sessionID: sessionID, changes: changes)
                    }
                    return
                }

                // Slow path: structural change, full recompile.
                // Reuse the existing session so traits set via preview_configure are
                // preserved without a race — compile() re-reads the source file and
                // uses the session's stored traits, which live inside the actor.
                fputs("Structural change, recompiling...\n", stderr)
                do {
                    guard
                        let existingSession = await MainActor.run(body: {
                            self.sessions[sessionID]
                        })
                    else {
                        fputs("Session \(sessionID) no longer exists\n", stderr)
                        return
                    }
                    let compileResult = try await existingSession.compile()
                    fputs("Compiled: \(compileResult.dylibPath.lastPathComponent)\n", stderr)

                    await MainActor.run {
                        do {
                            let existingFrame = self.windows[sessionID]?.frame
                            try self.loadPreview(
                                sessionID: sessionID,
                                dylibPath: compileResult.dylibPath,
                                title: "Preview: \(fileURL.lastPathComponent)",
                                size: existingFrame?.size ?? NSSize(width: 400, height: 600),
                                setupDylibPath: self.setupDylibPath
                            )
                            if let frame = existingFrame {
                                self.windows[sessionID]?.setFrameOrigin(frame.origin)
                            }
                            fputs("Reloaded!\n", stderr)
                        } catch {
                            fputs("Reload failed: \(error)\n", stderr)
                        }
                    }
                } catch {
                    fputs("Recompilation failed: \(error)\n", stderr)
                }
            }
        }
    }

    /// Apply literal-only changes by calling DesignTimeStore setters via dlsym.
    /// The @Observable DesignTimeStore triggers SwiftUI re-render automatically.
    @MainActor
    private func applyLiteralChanges(
        sessionID: String,
        changes: [(id: String, newValue: LiteralValue)]
    ) {
        guard let loader = loaders[sessionID] else {
            fputs("No loader for session \(sessionID)\n", stderr)
            return
        }

        for (id, value) in changes {
            do {
                switch value {
                case .string(let s):
                    typealias Setter = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
                    let fn: Setter = try loader.symbol(name: "designTimeSetString")
                    id.withCString { idPtr in s.withCString { valPtr in fn(idPtr, valPtr) } }

                case .integer(let n):
                    typealias Setter = @convention(c) (UnsafePointer<CChar>, Int) -> Void
                    let fn: Setter = try loader.symbol(name: "designTimeSetInteger")
                    id.withCString { idPtr in fn(idPtr, n) }

                case .float(let d):
                    typealias Setter = @convention(c) (UnsafePointer<CChar>, Double) -> Void
                    let fn: Setter = try loader.symbol(name: "designTimeSetFloat")
                    id.withCString { idPtr in fn(idPtr, d) }

                case .boolean(let b):
                    typealias Setter = @convention(c) (UnsafePointer<CChar>, Bool) -> Void
                    let fn: Setter = try loader.symbol(name: "designTimeSetBoolean")
                    id.withCString { idPtr in fn(idPtr, b) }
                }
            } catch {
                fputs("Failed to set design-time value \(id): \(error)\n", stderr)
            }
        }
        fputs("Applied \(changes.count) literal change(s) — @State preserved\n", stderr)
    }

    /// Close and clean up a preview window.
    public func closePreview(sessionID: String) {
        fileWatchers[sessionID]?.stop()
        fileWatchers.removeValue(forKey: sessionID)
        sessions.removeValue(forKey: sessionID)

        if let window = windows.removeValue(forKey: sessionID) {
            if let oldView = window.contentView {
                retainedViews.append(oldView)
            }
            window.contentView = nil
            window.orderOut(nil)
        }

        if let loader = loaders.removeValue(forKey: sessionID) {
            retainedLoaders.append(loader)
        }
    }

    /// Get the session for a session ID (for reconfiguration).
    public func session(for sessionID: String) -> PreviewSession? {
        sessions[sessionID]
    }

    /// All active macOS sessions, keyed by session ID. Used by session
    /// discovery (e.g., `snapshot <file>` looking for an existing session
    /// that matches the target source file).
    public var allSessions: [String: PreviewSession] { sessions }

    /// Get the window for a session (for snapshotting).
    public func window(for sessionID: String) -> NSWindow? {
        windows[sessionID]
    }
}

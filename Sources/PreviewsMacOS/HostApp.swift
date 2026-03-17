import AppKit
import SwiftUI
import PreviewsCore

/// Manages preview windows. Loads compiled dylibs and displays views in NSWindows.
@MainActor
public class PreviewHost: NSObject, NSApplicationDelegate {
    private var windows: [String: NSWindow] = [:]
    private var loaders: [String: DylibLoader] = [:]
    private var sessions: [String: PreviewSession] = [:]
    // Keep old loaders and views alive so their dylib types remain valid.
    private var retainedLoaders: [DylibLoader] = []
    private var retainedViews: [NSView] = []

    /// Callback invoked after NSApplication finishes launching.
    public var onLaunch: (@MainActor () -> Void)?

    /// When true, the app stays alive even after all windows close (for MCP serve mode).
    nonisolated(unsafe) public var keepAliveWithoutWindows = false

    private var fileWatchers: [String: FileWatcher] = [:]

    public func applicationDidFinishLaunching(_ notification: Notification) {
        onLaunch?()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return !keepAliveWithoutWindows
    }

    /// Load a dylib and display its preview view in a window.
    /// If a window already exists for this session, reuses it (swaps content view).
    public func loadPreview(
        sessionID: String,
        dylibPath: URL,
        entryPoint: String = "createPreviewView",
        title: String = "Preview",
        size: NSSize = NSSize(width: 400, height: 600)
    ) throws {
        // Retire the old loader (keep it alive, don't dlclose)
        if let oldLoader = loaders.removeValue(forKey: sessionID) {
            retainedLoaders.append(oldLoader)
        }

        // Load the new dylib
        let loader = try DylibLoader(path: dylibPath.path)
        loaders[sessionID] = loader

        // Resolve the entry point and create the view
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let createView: CreateFunc = try loader.symbol(name: entryPoint)
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
                styleMask: [.titled, .closable, .resizable, .miniaturizable],
                backing: .buffered,
                defer: false
            )
            window.title = title
            window.center()
            window.contentView = hostingView
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            windows[sessionID] = window
        }
    }

    /// Start watching a source file and reload the preview on changes.
    /// Uses the fast path (literal-only update via DesignTimeStore) when possible.
    public func watchFile(
        sessionID: String,
        session: PreviewSession,
        filePath: String,
        compiler: Compiler,
        previewIndex: Int
    ) {
        sessions[sessionID] = session
        let fileURL = URL(fileURLWithPath: filePath)
        fileWatchers[sessionID]?.stop()
        fileWatchers[sessionID] = try? FileWatcher(path: filePath) { [weak self] in
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
                   !changes.isEmpty {
                    fputs("Literal-only change: \(changes.count) value(s)\n", stderr)
                    await MainActor.run {
                        self.applyLiteralChanges(sessionID: sessionID, changes: changes)
                    }
                    return
                }

                // Slow path: structural change, full recompile
                fputs("Structural change, recompiling...\n", stderr)
                do {
                    let newSession = PreviewSession(
                        sourceFile: fileURL,
                        previewIndex: previewIndex,
                        compiler: compiler
                    )
                    let compileResult = try await newSession.compile()
                    fputs("Compiled: \(compileResult.dylibPath.lastPathComponent)\n", stderr)

                    await MainActor.run {
                        do {
                            self.sessions[sessionID] = newSession
                            let existingFrame = self.windows[sessionID]?.frame
                            try self.loadPreview(
                                sessionID: sessionID,
                                dylibPath: compileResult.dylibPath,
                                title: "Preview: \(fileURL.lastPathComponent)",
                                size: existingFrame?.size ?? NSSize(width: 400, height: 600)
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

    /// Get the window for a session (for snapshotting).
    public func window(for sessionID: String) -> NSWindow? {
        windows[sessionID]
    }
}

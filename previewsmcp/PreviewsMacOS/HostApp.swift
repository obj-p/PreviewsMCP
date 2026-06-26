import AppKit
import PreviewsCore
import SwiftUI

/// Manages preview sessions. Each session renders in its own agent process over
/// JIT; the daemon tracks session state and serves the agent-rendered snapshots.
///
/// Only one runtime shape remains since the CLI/MCP parity migration:
/// `serve` is the sole subcommand that ever constructs a PreviewHost, and
/// it always wants a daemon that stays alive after the last session closes.
/// Earlier `.interactive` and `.snapshot` modes were removed once every
/// non-`serve` CLI command moved to the daemon client path.
@MainActor
public class PreviewHost: NSObject, NSApplicationDelegate {
    private var sessions: [String: PreviewSession] = [:]
    /// Latest agent-rendered PNG per session. Set once a session goes through the
    /// JIT structural-reload path; `preview_snapshot` serves this for the session.
    private var agentImagePaths: [String: URL] = [:]

    /// Callback invoked after NSApplication finishes launching.
    public var onLaunch: (@MainActor () -> Void)?

    /// Makes the structural-reload strategy for the JIT path. Injected at the
    /// composition root. Each session gets its own reloader — its own agent
    /// process and window — so respawns, crashes, setup state, and window
    /// lifetime stay contained to one session.
    private let makeStructuralReloader: @MainActor () -> any StructuralReloader
    /// Per-session reloaders. Removing a session's entry releases its agent
    /// process, which closes the agent-hosted window.
    private var reloaders: [String: any StructuralReloader] = [:]
    /// Window placement for sessions started on the agent surface, where no
    /// daemon window exists to derive it from. Baked into each JIT compile.
    private var agentWindowSpecs: [String: JITRenderWindow] = [:]

    /// Async sink that publishes a snapshot of macOS sessions to the
    /// cross-process registry. Set once by the engine layer at host
    /// construction; not reassigned per MCP connection.
    public var publishSessions: (@Sendable ([(id: String, sourceFile: URL)]) async -> Void)?

    /// Tail of the chained publish queue. Every `notifySessionsChanged`
    /// call snapshots the current sessions on MainActor and spawns a
    /// Task that `await`s this prior Task before invoking
    /// `publishSessions`. Holding the chain guarantees FIFO arrival at
    /// the registry actor — without it, two MainActor mutations in
    /// quick succession can spawn Tasks that race for the registry's
    /// queue and persist the older snapshot last.
    private var lastPublishTask: Task<Void, Never>?

    public init(makeStructuralReloader: @escaping @MainActor () -> any StructuralReloader) {
        self.makeStructuralReloader = makeStructuralReloader
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

    public func applicationDidFinishLaunching(_: Notification) {
        onLaunch?()
    }

    public func applicationShouldTerminateAfterLastWindowClosed(_: NSApplication) -> Bool {
        // The daemon must stay alive after all preview windows close so
        // it can accept new session requests without a cold restart.
        false
    }

    /// Start watching source files and reload the preview on changes.
    /// Uses the fast path (literal-only update via DesignTimeStore) when possible.
    /// When `additionalPaths` is provided, watches all target files for cross-file changes.
    public func watchFile(
        sessionID: String,
        session: PreviewSession,
        filePath: String,
        compiler _: Compiler,
        additionalPaths: [String] = [],
        buildContext _: BuildContext? = nil
    ) {
        sessions[sessionID] = session
        notifySessionsChanged()
        let allPaths = [filePath] + additionalPaths
        let canonicalPrimary = FileWatcher.canonicalPath(filePath) ?? filePath
        fileWatchers[sessionID]?.stop()
        fileWatchers[sessionID] = try? FileWatcher(paths: allPaths) { [weak self] firedPaths in
            Task {
                await self?.handleWatchedChange(
                    sessionID: sessionID, canonicalPrimary: canonicalPrimary, firedPaths: firedPaths
                )
            }
        }
    }

    /// Apply a watcher burst to a session. An UNCHANGED primary file (no-op save, mtime touch,
    /// atomic-rename replay) does nothing so live `@State` is preserved. A literal-only edit
    /// re-renders in place. A structural edit, or any burst that touched a SECONDARY watched
    /// file (a cross-file dependency), recompiles. The slow path reuses the existing session so
    /// traits set via `preview_configure` survive.
    func handleWatchedChange(
        sessionID: String, canonicalPrimary: String, firedPaths: Set<String>
    ) async {
        guard let session = sessions[sessionID] else {
            fputs("Session \(sessionID) no longer exists\n", stderr)
            return
        }
        Log.info("jit_latency: watch-fire")

        let newSource = try? String(contentsOf: session.sourceFile, encoding: .utf8)
        let kind: PreviewSession.SourceChangeKind = if let newSource {
            await session.classifyWatchedChange(
                firedPaths: firedPaths, canonicalPrimary: canonicalPrimary, newPrimarySource: newSource
            )
        } else {
            .structural
        }

        switch kind {
        case .unchanged:
            fputs("Unchanged source, preserving state (no reload)\n", stderr)
            return
        case let .literal(changes):
            fputs("Literal-only change: \(changes.count) value(s)\n", stderr)
            do {
                if try await jitLiteralReload(
                    sessionID: sessionID, session: session, changes: changes
                ) != nil {
                    if let newSource { await session.commitSourceBaseline(newSource) }
                    fputs("Literal re-rendered in agent (no recompile)\n", stderr)
                    return
                }
            } catch {
                fputs("JIT literal reload failed: \(error)\n", stderr)
                return
            }
        // No prior JIT build to patch: fall through to a structural reload.
        case .structural:
            break
        }

        fputs("Structural change, recompiling...\n", stderr)
        do {
            _ = try await jitStructuralReload(sessionID: sessionID, session: session)
            fputs("Reloaded (JIT agent)!\n", stderr); fflush(stderr)
        } catch {
            fputs("Recompilation failed: \(error)\n", stderr)
        }
    }

    /// Close and clean up a preview session. Dropping the session's reloader kills
    /// its agent process, closing the agent-hosted window with it.
    public func closePreview(sessionID: String) {
        fileWatchers[sessionID]?.stop()
        fileWatchers.removeValue(forKey: sessionID)
        sessions.removeValue(forKey: sessionID)
        agentImagePaths.removeValue(forKey: sessionID)
        reloaders.removeValue(forKey: sessionID)
        agentWindowSpecs.removeValue(forKey: sessionID)
        notifySessionsChanged()
    }

    /// Get the session for a session ID (for reconfiguration).
    public func session(for sessionID: String) -> PreviewSession? {
        sessions[sessionID]
    }

    /// All active macOS sessions, keyed by session ID. Used by session
    /// discovery (e.g., `snapshot <file>` looking for an existing session
    /// that matches the target source file).
    public var allSessions: [String: PreviewSession] {
        sessions
    }

    /// Structural reload via the JIT path: compile the preview to a render-bridge
    /// object, render it in the agent, and record the agent's PNG for snapshots.
    /// Returns the agent's image path.
    ///
    /// For a visible session the session's window spec is baked into the bridge
    /// so the agent shows its own live window there — the agent window is the
    /// session's interactive surface.
    @discardableResult
    public func jitStructuralReload(sessionID: String, session: PreviewSession) async throws -> URL {
        restoreAgentWindowFrame(sessionID: sessionID, session: session)
        let build = try await session.compileObjectForJIT(window: agentWindowSpec(for: sessionID))
        return try await jitRender(sessionID: sessionID, build: build)
    }

    /// Before a structural reload, bake the agent's last recorded window frame into the session's
    /// spec so a respawned agent restores the user's dragged/resized window instead of recentering
    /// (#195). Only for visible sessions; absent sidecar keeps the stored spec unchanged.
    private func restoreAgentWindowFrame(sessionID: String, session: PreviewSession) {
        guard let spec = agentWindowSpecs[sessionID], !spec.headless,
              let frame = PreviewSession.storedWindowFrame(for: session.id)
        else { return }
        agentWindowSpecs[sessionID] = JITRenderWindow(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height,
            title: spec.title, headless: false
        )
    }

    /// Start a session with the agent as its surface from the first render: no
    /// in-daemon dylib compile, no daemon window. The requested placement becomes
    /// the session's window spec, centered on the main screen for visible sessions
    /// (no spec when there is no screen to place it on). Registers the session up
    /// front so the reloader can be created, and tears everything down if the
    /// first render fails.
    public func jitStart(
        sessionID: String, session: PreviewSession,
        title: String, size: NSSize, headless: Bool
    ) async throws {
        sessions[sessionID] = session
        if !headless, let screen = NSScreen.main?.visibleFrame {
            agentWindowSpecs[sessionID] = JITRenderWindow(
                x: screen.midX - size.width / 2,
                y: screen.midY - size.height / 2,
                width: size.width, height: size.height,
                title: title
            )
        } else {
            // Headless, or no screen to place a visible window on: still bake the requested size
            // so the render matches it; the bridge keeps this window off-screen and unshown.
            agentWindowSpecs[sessionID] = JITRenderWindow(
                x: 0, y: 0, width: size.width, height: size.height, title: title, headless: true
            )
        }
        do {
            try await jitStructuralReload(sessionID: sessionID, session: session)
        } catch {
            closePreview(sessionID: sessionID)
            throw error
        }
    }

    /// The session's reloader, created on first use. One per session: each owns
    /// its own agent process. Created only for registered sessions, so a reload
    /// still in flight when its session closes cannot resurrect an agent.
    private func reloader(for sessionID: String) -> (any StructuralReloader)? {
        if let existing = reloaders[sessionID] { return existing }
        guard sessions[sessionID] != nil else { return nil }
        let made = makeStructuralReloader()
        reloaders[sessionID] = made
        return made
    }

    /// The window spec (size + placement + headless flag) to bake into a JIT build for this
    /// session, stored at agent start. Nil only when the session never went through `jitStart`.
    public func agentWindowSpec(for sessionID: String) -> JITRenderWindow? {
        agentWindowSpecs[sessionID]
    }

    /// Render a JIT build in the agent and make its PNG the session's snapshot source.
    @discardableResult
    public func jitRender(sessionID: String, build: JITRenderBuild) async throws -> URL {
        guard let reloader = reloader(for: sessionID) else {
            throw SnapshotError.captureFailed
        }
        try await reloader.render(build)
        agentImagePaths[sessionID] = build.imagePath
        return build.imagePath
    }

    /// The agent-rendered PNG for a session, if it is on the JIT structural path.
    public func agentSnapshotPath(for sessionID: String) -> URL? {
        agentImagePaths[sessionID]
    }

    /// Literal-only reload for an agent-backed session: rewrite the design-time values
    /// JSON and re-render the same object in the agent — no recompile. Returns the new
    /// image path, or nil if there is no reloader or no prior JIT build.
    @discardableResult
    public func jitLiteralReload(
        sessionID: String,
        session: PreviewSession,
        changes: [(id: String, newValue: LiteralValue)]
    ) async throws -> URL? {
        guard
            let reloader = reloader(for: sessionID),
            let build = try await session.applyLiteralValuesForJIT(changes)
        else { return nil }
        try await reloader.render(build)
        agentImagePaths[sessionID] = build.imagePath
        return build.imagePath
    }

    /// Snapshot the current sessions and chain a publish Task. Each new
    /// Task `await`s the prior `lastPublishTask` before calling
    /// `publishSessions`, guaranteeing FIFO order at the registry even
    /// though the publish itself runs on a different actor. All
    /// read/writes of `lastPublishTask` happen on MainActor (this
    /// method is not async), so the chain head is consistent.
    public func notifySessionsChanged() {
        guard let publishSessions else { return }
        let snapshot: [(id: String, sourceFile: URL)] = sessions.map {
            (id: $0.key, sourceFile: $0.value.sourceFile)
        }
        let prev = lastPublishTask
        lastPublishTask = Task { [publishSessions] in
            await prev?.value
            await publishSessions(snapshot)
        }
    }
}

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
    private var refreshers: [String: @Sendable () async throws -> BuildContext?] = [:]
    private var burstTails: [String: Task<Void, Never>] = [:]

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
    /// The watch set derives from the build context: the target's source
    /// files exactly, plus the captured evidence (stage 4) — runtime inputs
    /// and definition files exactly, source roots directory-scoped.
    /// `refresh` re-runs the session's native build and returns a fresh
    /// context; it powers the evidence tiers and is kept across reinstalls.
    public func watchFile(
        sessionID: String,
        session: PreviewSession,
        filePath: String,
        buildContext: BuildContext? = nil,
        refresh: (@Sendable () async throws -> BuildContext?)? = nil
    ) {
        sessions[sessionID] = session
        notifySessionsChanged()
        refreshers[sessionID] = refresh
        let watchSet = WatchSet.derive(primary: filePath, buildContext: buildContext)
        let canonicalPrimary = FileWatcher.canonicalPath(filePath) ?? filePath
        fileWatchers[sessionID]?.stop()
        fileWatchers[sessionID] = try? FileWatcher(
            paths: watchSet.paths, directories: watchSet.directories
        ) { [weak self] firedPaths in
            Task { @MainActor in
                self?.enqueueWatchedChange(
                    sessionID: sessionID, canonicalPrimary: canonicalPrimary,
                    firedPaths: firedPaths
                )
            }
        }
    }

    /// Serialize burst handling per session: the whole reaction — for the
    /// evidence tiers, native build through reload — runs under this chain,
    /// and a burst arriving mid-refresh waits, then classifies against the
    /// already-swapped context, so consumed changes damp to no-ops and an
    /// undowngraded follow-up runs for real ones (the stage-4 per-session
    /// mutex macOS gains).
    private func enqueueWatchedChange(
        sessionID: String, canonicalPrimary: String, firedPaths: Set<String>
    ) {
        let previous = burstTails[sessionID]
        burstTails[sessionID] = Task { [weak self] in
            await previous?.value
            await self?.handleWatchedChange(
                sessionID: sessionID, canonicalPrimary: canonicalPrimary,
                firedPaths: firedPaths
            )
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
        let action: PreviewSession.WatchedBurstAction = if let newSource {
            await session.classifyWatchedBurst(
                firedPaths: firedPaths, canonicalPrimary: canonicalPrimary, newPrimarySource: newSource
            )
        } else {
            .fastPath(.structural)
        }

        let kind: PreviewSession.SourceChangeKind
        switch action {
        case .refresh, .reresolve:
            await refreshSession(sessionID: sessionID, session: session)
            return
        case let .fastPath(fastPathKind):
            kind = fastPathKind
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

    /// Re-run the native build after an evidence change, swap the session's
    /// compile context, reinstall the watcher from the fresh EvidenceSet,
    /// then structurally reload (docs/state-invalidation.md stage 4). A
    /// resolution that no longer finds a build system keeps the current
    /// preview rather than rendering against a stale context.
    private func refreshSession(sessionID: String, session: PreviewSession) async {
        guard let refresh = refreshers[sessionID] else {
            fputs("Evidence change but no rebuilder; structural reload only\n", stderr)
            do {
                _ = try await jitStructuralReload(sessionID: sessionID, session: session)
            } catch {
                fputs("Recompilation failed: \(error)\n", stderr)
            }
            return
        }
        fputs("Evidence change: re-running the native build...\n", stderr)
        do {
            guard let newContext = try await refresh() else {
                fputs(
                    "Refresh: no build system resolves \(session.sourceFile.path) anymore; keeping current preview\n",
                    stderr
                )
                return
            }
            await session.replaceBuildContext(newContext)
            watchFile(
                sessionID: sessionID, session: session,
                filePath: session.sourceFile.path,
                buildContext: newContext, refresh: refresh
            )
            _ = try await jitStructuralReload(sessionID: sessionID, session: session)
            fputs("Refreshed (native rebuild + reload)\n", stderr); fflush(stderr)
        } catch {
            fputs("Refresh failed: \(error)\n", stderr)
        }
    }

    /// Close and clean up a preview session. Dropping the session's reloader kills
    /// its agent process, closing the agent-hosted window with it.
    public func closePreview(sessionID: String) {
        fileWatchers[sessionID]?.stop()
        fileWatchers.removeValue(forKey: sessionID)
        refreshers.removeValue(forKey: sessionID)
        burstTails.removeValue(forKey: sessionID)
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

    /// Before a structural reload, bake the agent's last recorded window placement into the
    /// session's spec so a respawned agent restores the user's dragged/resized window instead
    /// of recentering (#195). The sidecar records the content rect — the same space the spec
    /// bakes — so no frame conversion happens here. Only for visible sessions; absent sidecar
    /// keeps the stored spec unchanged.
    private func restoreAgentWindowFrame(sessionID: String, session: PreviewSession) {
        guard let spec = agentWindowSpecs[sessionID], !spec.headless,
              let frame = PreviewSession.storedWindowFrame(for: session.id)
        else { return }
        agentWindowSpecs[sessionID] = JITRenderWindow(
            x: frame.x, y: frame.y, width: frame.width, height: frame.height,
            title: spec.title, headless: false, activates: spec.activates
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

    /// Re-raster the live window to the session's image path before a snapshot, so
    /// `preview_snapshot` reflects post-render interaction on a visible session (#346).
    /// Only visible sessions run the generated `snapshotPreviewWindow` entry — headless ones
    /// no-op, their render-time PNG is already the truth. No-op too without a reloader. Throws
    /// a raster failure so the caller can decide whether to surface it or fall back to the last
    /// good PNG (the handle falls back).
    public func refreshLiveSnapshot(sessionID: String) async throws {
        guard agentWindowSpecs[sessionID]?.headless == false,
              let reloader = reloaders[sessionID]
        else { return }
        try await reloader.snapshotLiveWindow(entrySymbol: "snapshotPreviewWindow")
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

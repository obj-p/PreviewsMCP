import Foundation
import PreviewsCore

/// `StructuralReloader` backed by the remote JIT agent, capped-persistent: one agent serves
/// many edits, each linked into a fresh `JITDylib` (`newGeneration`), and the agent respawns
/// every `generationCap` edits. Respawn bounds the unreclaimable `__swift5_*` metadata that
/// each generation leaks (it cannot be deregistered). The render entry runs on the agent's
/// main thread and writes the preview PNG to the path baked into the object at compile time.
///
/// A respawn is a seamless handoff (#254): the fresh agent is stood up completely — spawned,
/// linked, first render, so its window is on screen at the baked frame — before the old
/// session is replaced, whose `deinit` kills the old agent and closes its window. The reverse
/// order shows the desktop in the gap. A failure anywhere leaves the old agent, its window,
/// and this actor's state untouched, so the last good preview stays up.
public actor JITStructuralReloader: StructuralReloader {
    private let generationCap: Int
    private var session: JITSession?
    private var generation = 0
    private var lastObjectPath: URL?
    private var didRunSetUp = false

    public init(generationCap: Int = 100) {
        self.generationCap = generationCap
    }

    public func render(_ build: JITRenderBuild) async throws {
        // Literal re-render: the same object is already linked in the live generation, so just
        // re-run its entry. It re-seeds DesignTimeStore from the (rewritten) values JSON, with
        // no new JITDylib and no re-link (which would re-register the object's classes).
        if let session, build.objectPath == lastObjectPath {
            let mark = ContinuousClock.now
            try Self.run(session, build.entrySymbol)
            Log.info("jit_latency: render-entry-literal \(Log.millis(mark, ContinuousClock.now))ms")
            return
        }

        // A fresh `JITDylib` on the live agent while under the cap. The first edit, each
        // post-cap edit, and any `forceFresh` edit (the non-leaf incremental split, which
        // reuses the target's stable module name) hand off to a new agent instead.
        if let session, !build.requiresFreshAgent, generation < generationCap {
            generation += 1
            try session.newGeneration()
            try link(build, into: session)
            lastObjectPath = build.objectPath
            // Setup runs once per agent process (its plugin state lives for the process's
            // lifetime), so re-run after a respawn but not per generation. The entry is
            // void; the wrapper's status word is meaningless for it.
            if let setupEntry = build.setupEntrySymbol, !didRunSetUp {
                _ = try session.runOnMain(symbol: setupEntry)
                didRunSetUp = true
            }
            let mark = ContinuousClock.now
            try Self.run(session, build.entrySymbol)
            Log.info("jit_latency: render-entry \(Log.millis(mark, ContinuousClock.now))ms")
            return
        }

        var mark = ContinuousClock.now
        let fresh = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        Log.info(
            "jit_latency: agent-session force-fresh=\(build.requiresFreshAgent) "
                + "\(Log.millis(mark, ContinuousClock.now))ms"
        )
        try link(build, into: fresh)
        if let setupEntry = build.setupEntrySymbol {
            _ = try fresh.runOnMain(symbol: setupEntry)
        }
        mark = ContinuousClock.now
        try Self.run(fresh, build.entrySymbol)
        Log.info("jit_latency: render-entry \(Log.millis(mark, ContinuousClock.now))ms")
        // The fresh agent's window is up; replacing the session now kills the old agent.
        session = fresh
        generation = 1
        didRunSetUp = build.setupEntrySymbol != nil
        lastObjectPath = build.objectPath
    }

    private func link(_ build: JITRenderBuild, into session: JITSession) throws {
        var mark = ContinuousClock.now
        for dylib in build.dylibPaths {
            try session.addDylib(path: dylib.path)
        }
        for archive in build.archivePaths {
            try session.addArchive(path: archive.path)
        }
        Log.info(
            "jit_latency: add-deps dylibs=\(build.dylibPaths.count) "
                + "archives=\(build.archivePaths.count) \(Log.millis(mark, ContinuousClock.now))ms"
        )
        mark = ContinuousClock.now
        for support in build.supportObjectPaths {
            try session.addObject(path: support.path)
        }
        try session.addObject(path: build.objectPath.path)
        Log.info(
            "jit_latency: add-objects \(build.supportObjectPaths.count + 1) "
                + "\(Log.millis(mark, ContinuousClock.now))ms"
        )
    }

    private static func run(_ session: JITSession, _ entrySymbol: String) throws {
        let status = try session.runOnMain(symbol: entrySymbol)
        guard status == 0 else {
            throw JITReloadError.renderFailed(status: status)
        }
    }
}

public enum JITReloadError: Error, LocalizedError, CustomStringConvertible {
    case renderFailed(status: Int32)

    public var description: String {
        switch self {
        case let .renderFailed(status):
            "JIT render entry returned non-zero status \(status)"
        }
    }

    public var errorDescription: String? {
        description
    }
}

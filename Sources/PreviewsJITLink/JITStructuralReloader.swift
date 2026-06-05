import Foundation
import PreviewsCore

/// `StructuralReloader` backed by the remote JIT agent, capped-persistent: one agent serves
/// many edits, each linked into a fresh `JITDylib` (`newGeneration`), and the agent respawns
/// every `generationCap` edits. Respawn bounds the unreclaimable `__swift5_*` metadata that
/// each generation leaks (it cannot be deregistered). The render entry runs on the agent's
/// main thread and writes the preview PNG to the path baked into the object at compile time.
public actor JITStructuralReloader: StructuralReloader {
    private let generationCap: Int
    private var session: JITSession?
    private var generation = 0
    private var lastObjectPath: URL?

    public init(generationCap: Int = 100) {
        self.generationCap = generationCap
    }

    public func render(_ build: JITRenderBuild) async throws {
        // Literal re-render: the same object is already linked in the live generation, so just
        // re-run its entry. It re-seeds DesignTimeStore from the (rewritten) values JSON, with
        // no new JITDylib and no re-link (which would re-register the object's classes).
        if let session, build.objectPath == lastObjectPath {
            try Self.run(session, build.entrySymbol)
            return
        }

        let session = try nextSession()
        for dylib in build.dylibPaths {
            try session.addDylib(path: dylib.path)
        }
        for archive in build.archivePaths {
            try session.addArchive(path: archive.path)
        }
        for support in build.supportObjectPaths {
            try session.addObject(path: support.path)
        }
        try session.addObject(path: build.objectPath.path)
        lastObjectPath = build.objectPath
        try Self.run(session, build.entrySymbol)
    }

    private static func run(_ session: JITSession, _ entrySymbol: String) throws {
        let status = try session.runOnMain(symbol: entrySymbol)
        guard status == 0 else {
            throw JITReloadError.renderFailed(status: status)
        }
    }

    /// The session to link this edit into: a fresh `JITDylib` on the live agent while under
    /// the cap, otherwise a freshly respawned agent (replacing the old one, whose `deinit`
    /// kills its process). The first edit and each post-cap edit start a new agent.
    private func nextSession() throws -> JITSession {
        if let session, generation < generationCap {
            generation += 1
            try session.newGeneration()
            return session
        }
        let fresh = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        session = fresh
        generation = 1
        return fresh
    }
}

public enum JITReloadError: Error, CustomStringConvertible {
    case renderFailed(status: Int32)

    public var description: String {
        switch self {
        case .renderFailed(let status):
            return "JIT render entry returned non-zero status \(status)"
        }
    }
}

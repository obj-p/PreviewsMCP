import Foundation
import PreviewsCore

/// `IOSStructuralReloader` backed by the in-app ORC executor reached over an EPC socket.
///
/// Unlike `JITStructuralReloader`, the iOS reloader cannot respawn its executor: the
/// executor lives inside the long-running simulator host app, reached over a single
/// accepted EPC fd. So one `JITSession` serves every edit for the session's lifetime,
/// linking each structural edit into a fresh `JITDylib` (`newGeneration`). A full host
/// restart, when needed to bound leaked `__swift5_*` metadata, is driven by the daemon
/// via `simctl`, not from here.
public actor IOSJITStructuralReloader: IOSStructuralReloader {
    private let session: JITSession
    private var generation = 0
    private var lastObjectPath: URL?
    private var didRunSetUp = false

    public init(remoteFD fd: Int32, orcRuntimePath: String) throws {
        session = try JITSession(remoteFD: fd, orcRuntimePath: orcRuntimePath)
    }

    public func render(_ build: JITRenderBuild) async throws {
        // Literal re-render: the same object is already linked in the live generation, so just
        // re-run its entry. It re-seeds DesignTimeStore from the (rewritten) values JSON, with
        // no new JITDylib and no re-link (which would re-register the object's classes).
        if let lastObjectPath, build.objectPath == lastObjectPath {
            try await runEntry(build.entrySymbol)
            return
        }

        // Structural edit: compileObjectForJIT minted a new objectPath, so link it into a
        // fresh generation.
        if generation > 0 {
            try session.newGeneration()
        }
        generation += 1

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

        if let setupEntry = build.setupEntrySymbol, !didRunSetUp {
            _ = try session.runOnMain(symbol: setupEntry)
            didRunSetUp = true
        }
        try await runEntry(build.entrySymbol)
    }

    /// Run the render entry, re-running it (no relink) on the iOS entry's `-1` "no key
    /// window yet" status. The host installs a placeholder root controller at launch, but
    /// the first render can race window attachment on a cold simulator; a few short retries
    /// cover that without failing `start()`. Any other non-zero status fails immediately.
    private func runEntry(_ entrySymbol: String) async throws {
        for attempt in 1 ... 5 {
            let status = try session.runOnMain(symbol: entrySymbol)
            if status == 0 { return }
            guard status == -1, attempt < 5 else {
                throw JITReloadError.renderFailed(status: status)
            }
            try await Task.sleep(for: .milliseconds(200))
        }
    }
}

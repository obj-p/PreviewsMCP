import Foundation
import PreviewsCore
import PreviewsMacOS

/// macOS adapter for `PreviewSessionHandle`. Bundles the
/// `PreviewSession + PreviewHost.window/loadPreview/closePreview` plus
/// the 300ms post-`setTraits` layout-settle pause that the SwiftUI
/// hosting view needs before a snapshot. Encapsulating the pause here
/// keeps it out of MCP tool handlers.
public actor MacOSPreviewHandle: PreviewSessionHandle {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let platform: PreviewPlatform = .macOS

    private let session: PreviewSession
    private let host: PreviewHost

    public init(id: String, session: PreviewSession, host: PreviewHost) {
        self.id = id
        self.sourceFile = session.sourceFile
        self.session = session
        self.host = host
    }

    public var currentTraits: PreviewTraits {
        get async { await session.currentTraits }
    }

    public var isRegistered: Bool {
        get async {
            await MainActor.run { host.allSessions[id] != nil }
        }
    }

    /// Compile and reload the dylib into the host window. Does NOT
    /// pause for layout — call `awaitLayoutSettle()` between this and a
    /// subsequent snapshot. Folding the settle into `setTraits` would
    /// add 300ms to the variants restore step (which does not snapshot)
    /// and is what tipped CI's `preview_variants` test over its 60s
    /// callTool budget.
    public func setTraits(_ traits: PreviewTraits) async throws {
        if let route = await agentRoute() {
            let build = try await session.setTraitsForJIT(traits, window: route.window)
            try await host.jitRender(sessionID: id, build: build)
            return
        }
        let result = try await session.setTraits(traits)
        try await MainActor.run {
            try host.loadPreview(sessionID: id, dylibPath: result.dylibPath)
        }
    }

    public func reconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) async throws {
        if let route = await agentRoute() {
            let build = try await session.reconfigureForJIT(
                traits: traits, clearing: clearing, window: route.window)
            try await host.jitRender(sessionID: id, build: build)
            return
        }
        let result = try await session.reconfigure(traits: traits, clearing: clearing)
        try await MainActor.run {
            try host.loadPreview(sessionID: id, dylibPath: result.dylibPath)
        }
    }

    public func switchPreview(to index: Int) async throws {
        if let route = await agentRoute() {
            let build = try await session.switchPreviewForJIT(to: index, window: route.window)
            try await host.jitRender(sessionID: id, build: build)
            return
        }
        let result = try await session.switchPreview(to: index)
        try await MainActor.run {
            try host.loadPreview(sessionID: id, dylibPath: result.dylibPath)
        }
    }

    /// Non-nil when the session is agent-backed and a JIT reloader is present, so
    /// switch/configure must re-render in the agent instead of reloading a dylib
    /// into the daemon window (which would resurrect it as a second, stale surface).
    private struct AgentRoute {
        let window: JITRenderWindow?
    }

    private func agentRoute() async -> AgentRoute? {
        await MainActor.run {
            guard host.structuralReloader != nil, host.agentSnapshotPath(for: id) != nil else {
                return nil
            }
            return AgentRoute(window: host.agentWindowSpec(for: id))
        }
    }

    public func snapshot(quality: Double) async throws -> Data {
        let format: Snapshot.ImageFormat = quality >= 1.0 ? .png : .jpeg(quality: quality)
        let sessionID = id
        return try await MainActor.run {
            if let imagePath = host.agentSnapshotPath(for: sessionID) {
                return try Snapshot.encode(imageAt: imagePath, format: format)
            }
            guard let window = host.window(for: sessionID) else {
                throw SnapshotError.captureFailed
            }
            return try Snapshot.capture(window: window, format: format)
        }
    }

    public func stop() async {
        let sessionID = id
        await MainActor.run {
            host.closePreview(sessionID: sessionID)
        }
    }

    public func awaitLayoutSettle() async {
        // SwiftUI lays out asynchronously after a contentView swap. 300ms
        // gives the run loop time for at least one layout+display pass
        // before `cacheDisplay` reads the frame.
        try? await Task.sleep(for: .milliseconds(300))
    }
}

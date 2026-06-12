import AppKit
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
        try await reload(
            jit: { try await self.session.setTraitsForJIT(traits, window: $0) },
            dylib: { try await self.session.setTraits(traits) })
    }

    public func reconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) async throws {
        try await reload(
            jit: { try await self.session.reconfigureForJIT(traits: traits, clearing: clearing, window: $0) },
            dylib: { try await self.session.reconfigure(traits: traits, clearing: clearing) })
    }

    public func switchPreview(to index: Int) async throws {
        try await reload(
            jit: { try await self.session.switchPreviewForJIT(to: index, window: $0) },
            dylib: { try await self.session.switchPreview(to: index) })
    }

    /// The single routing seam for every mutating reload. In a JIT build every
    /// session re-renders in its agent; in a non-JIT build every session reloads
    /// a dylib into its daemon window. The split is per-build, never per-session.
    private func reload(
        jit: (JITRenderWindow?) async throws -> JITRenderBuild,
        dylib: () async throws -> CompileResult
    ) async throws {
        enum Surface {
            case agent(JITRenderWindow?)
            case daemonWindow
        }
        let surface: Surface = await MainActor.run {
            guard host.agentBacked else {
                return .daemonWindow
            }
            return .agent(host.agentWindowSpec(for: id))
        }
        switch surface {
        case .agent(let window):
            let build = try await jit(window)
            try await host.jitRender(sessionID: id, build: build)
        case .daemonWindow:
            let result = try await dylib()
            try await MainActor.run {
                try host.loadPreview(sessionID: id, dylibPath: result.dylibPath)
            }
        }
    }

    public func snapshot(quality: Double) async throws -> Data {
        let format: Snapshot.ImageFormat = quality >= 1.0 ? .png : .jpeg(quality: quality)
        let sessionID = id
        let colorScheme = await session.currentTraits.colorScheme
        return try await MainActor.run {
            if host.agentBacked {
                guard let imagePath = host.agentSnapshotPath(for: sessionID) else {
                    throw SnapshotError.captureFailed
                }
                let appearance: NSAppearance? =
                    switch colorScheme {
                    case "dark": NSAppearance(named: .darkAqua)
                    case "light": NSAppearance(named: .aqua)
                    default: NSApplication.shared.effectiveAppearance
                    }
                return try Snapshot.encode(
                    imageAt: imagePath, format: format, flattenedWith: appearance)
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

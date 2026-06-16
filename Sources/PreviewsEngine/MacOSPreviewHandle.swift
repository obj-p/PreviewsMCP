import AppKit
import Foundation
import PreviewsCore
import PreviewsMacOS

/// macOS adapter for `PreviewSessionHandle`. Bundles the
/// `PreviewSession + PreviewHost.jitRender/closePreview` plus
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
        try await reload { try await self.session.setTraitsForJIT(traits, window: $0) }
    }

    public func reconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) async throws {
        try await reload {
            try await self.session.reconfigureForJIT(traits: traits, clearing: clearing, window: $0)
        }
    }

    public func switchPreview(to index: Int) async throws {
        try await reload { try await self.session.switchPreviewForJIT(to: index, window: $0) }
    }

    /// Shared window-spec + render plumbing for every mutating reload. Every
    /// session re-renders in its agent over JIT.
    private func reload(
        _ jit: (JITRenderWindow?) async throws -> JITRenderBuild
    ) async throws {
        let window = await MainActor.run { host.agentWindowSpec(for: id) }
        let build = try await jit(window)
        try await host.jitRender(sessionID: id, build: build)
    }

    public func snapshot(quality: Double) async throws -> Data {
        let format: Snapshot.ImageFormat = quality >= 1.0 ? .png : .jpeg(quality: quality)
        let sessionID = id
        let colorScheme = await session.currentTraits.colorScheme
        return try await MainActor.run {
            guard let imagePath = host.agentSnapshotPath(for: sessionID) else {
                throw SnapshotError.captureFailed
            }
            let named: NSAppearance? =
                switch colorScheme {
                case "dark": NSAppearance(named: .darkAqua)
                case "light": NSAppearance(named: .aqua)
                default: nil
                }
            let appearance = named ?? NSApplication.shared.effectiveAppearance
            return try Snapshot.encode(
                imageAt: imagePath, format: format, flattenedWith: appearance)
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

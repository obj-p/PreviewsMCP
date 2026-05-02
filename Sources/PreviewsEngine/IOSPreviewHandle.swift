import Foundation
import PreviewsCore
import PreviewsIOS

/// iOS adapter for `PreviewSessionHandle`. Wraps `IOSPreviewSession` and
/// the `IOSSessionManager` registry so `stop()` both tears down the
/// simulator-side session and removes it from the manager — symmetric
/// with the macOS side, where `host.closePreview` does both at once.
public actor IOSPreviewHandle: PreviewSessionHandle {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let platform: PreviewPlatform = .iOS

    private let iosSession: IOSPreviewSession
    private let manager: IOSSessionManager

    public init(iosSession: IOSPreviewSession, manager: IOSSessionManager) {
        self.id = iosSession.id
        self.sourceFile = iosSession.sourceFile
        self.iosSession = iosSession
        self.manager = manager
    }

    public var currentTraits: PreviewTraits {
        get async { await iosSession.currentTraits }
    }

    public var isRegistered: Bool {
        get async {
            await manager.getSession(id) != nil
        }
    }

    public func setTraits(_ traits: PreviewTraits) async throws {
        try await iosSession.setTraits(traits)
    }

    public func reconfigure(traits: PreviewTraits, clearing: Set<PreviewTraits.Field>) async throws {
        try await iosSession.reconfigure(traits: traits, clearing: clearing)
    }

    public func switchPreview(to index: Int) async throws {
        try await iosSession.switchPreview(to: index)
    }

    public func snapshot(quality: Double) async throws -> Data {
        try await iosSession.screenshot(jpegQuality: quality)
    }

    public func stop() async {
        await iosSession.stop()
        await manager.removeSession(id)
    }
}

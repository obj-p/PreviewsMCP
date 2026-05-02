import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsMacOS

/// Resolves a session ID to a `PreviewSessionHandle`, hiding which
/// backend (iOS simulator or macOS host) actually owns the session.
/// Constructed once per daemon connection and reused across MCP tool
/// handlers.
///
/// iOS is checked first: it's the more common platform in current usage
/// and the `IOSSessionManager` lookup is a single actor hop, while the
/// macOS lookup hops to MainActor. Order matters only for performance —
/// session IDs are UUIDs and never collide across backends.
public actor SessionRouter {
    private let host: PreviewHost
    private let iosManager: IOSSessionManager

    public init(host: PreviewHost, iosManager: IOSSessionManager) {
        self.host = host
        self.iosManager = iosManager
    }

    /// Returns a handle for the session with the given ID, or `nil` if
    /// no session matches in either backend.
    public func handle(for sessionID: String) async -> (any PreviewSessionHandle)? {
        if let iosSession = await iosManager.getSession(sessionID) {
            return IOSPreviewHandle(iosSession: iosSession, manager: iosManager)
        }
        let macSession: PreviewSession? = await MainActor.run {
            host.session(for: sessionID)
        }
        guard let macSession else { return nil }
        return MacOSPreviewHandle(id: sessionID, session: macSession, host: host)
    }
}

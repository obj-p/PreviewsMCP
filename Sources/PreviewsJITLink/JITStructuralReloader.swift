import Foundation
import PreviewsCore

/// `StructuralReloader` backed by the remote JIT agent. Spawns a fresh agent, links the
/// object, and runs its render entry on the agent's main thread; the entry writes the
/// preview PNG to the path baked into the object at compile time. The session's `deinit`
/// kills the agent, so this is respawn-per-edit; a capped-persistent variant can replace
/// the body without changing the protocol.
public struct JITStructuralReloader: StructuralReloader {
    public init() {}

    public func renderObject(at objectPath: URL, entrySymbol: String) async throws {
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: objectPath.path)
        let status = try session.runOnMain(symbol: entrySymbol)
        guard status == 0 else {
            throw JITReloadError.renderFailed(status: status)
        }
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

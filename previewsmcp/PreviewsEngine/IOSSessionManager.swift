import Foundation
import PreviewsCore
import PreviewsIOS

/// Tracks active iOS preview sessions and lazily creates shared iOS
/// resources (compiler, host builder). One instance is shared across
/// all daemon connections so sessions persist across CLI invocations.
public actor IOSSessionManager {
    public let simulatorManager = SimulatorManager()
    private var compiler: Compiler?
    private var agentBuilder: IOSAgentBuilder?
    private var sessions: [String: IOSPreviewSession] = [:]
    private var fileWatchers: [String: FileWatcher] = [:]
    private let claims = DeviceClaims()
    /// Cross-process session registry. When attached, every mutation
    /// republishes the current iOS session set so peer processes see
    /// our sessions in their `session_list` output.
    private var registry: SessionRegistry?

    public init() {}

    /// A start could not claim its device because a session in another
    /// live process occupies it. Replacement is within-process only — a
    /// foreign session cannot be stopped in an ordered way.
    public struct DeviceClaimedByPeer: Error, LocalizedError {
        public let deviceUDID: String
        public let sessionID: String

        public var errorDescription: String? {
            "Simulator \(deviceUDID) is in use by session \(sessionID) in another "
                + "previewsmcp process. Stop that session from its own client first."
        }
    }

    /// Claim `deviceUDID` for a starting session identified by the opaque
    /// `owner` token. Replaces a live in-process incumbent (returning its
    /// session ID for disclosure); fails fast when a live peer process
    /// occupies the device.
    public func claimDevice(_ deviceUDID: String, owner: String) async throws -> String? {
        if let registry,
           let foreign = await registry.readOthers()
           .first(where: { $0.deviceUDID == deviceUDID })
        {
            throw DeviceClaimedByPeer(deviceUDID: deviceUDID, sessionID: foreign.sessionID)
        }
        return await claims.claim(device: deviceUDID, owner: owner) { [weak self] sessionID in
            await self?.stopAndRemove(sessionID)
        }
    }

    /// Promote a claim to live after `start()` succeeded. A false return
    /// means this start was replaced while launching: the caller owns the
    /// teardown of its own session.
    public func confirmDeviceClaim(
        _ deviceUDID: String, owner: String, sessionID: String
    ) async -> Bool {
        await claims.confirmLive(device: deviceUDID, owner: owner, sessionID: sessionID)
    }

    /// Drop a claim whose start failed before the session went live.
    public func releaseDeviceClaim(_ deviceUDID: String, owner: String) async {
        await claims.release(device: deviceUDID, owner: owner)
    }

    private func stopAndRemove(_ id: String) async {
        guard let session = sessions[id] else { return }
        await session.stop()
        sessions.removeValue(forKey: id)
        fileWatchers[id]?.stop()
        fileWatchers.removeValue(forKey: id)
        await republish()
    }

    /// Attach a `SessionRegistry` so this manager publishes its iOS
    /// session set on every mutation. Idempotent — replacing the
    /// registry republishes against the new one.
    public func setRegistry(_ registry: SessionRegistry) async {
        self.registry = registry
        await republish()
    }

    public func getCompiler() async throws -> Compiler {
        if let c = compiler { return c }
        let c = try await Compiler(platform: .iOS)
        compiler = c
        return c
    }

    public func getAgentBuilder() async throws -> IOSAgentBuilder {
        if let b = agentBuilder { return b }
        let b = try await IOSAgentBuilder()
        agentBuilder = b
        return b
    }

    public func addSession(_ session: IOSPreviewSession) async {
        sessions[session.id] = session
        await republish()
    }

    public func getSession(_ id: String) -> IOSPreviewSession? {
        sessions[id]
    }

    public func removeSession(_ id: String) async {
        if let session = sessions[id] {
            await claims.releaseLive(device: session.deviceUDID, sessionID: id)
        }
        sessions.removeValue(forKey: id)
        fileWatchers[id]?.stop()
        fileWatchers.removeValue(forKey: id)
        await republish()
    }

    public func setFileWatcher(_ id: String, _ watcher: FileWatcher) {
        fileWatchers[id]?.stop()
        fileWatchers[id] = watcher
    }

    public func allSessionIDs() -> [String] {
        Array(sessions.keys)
    }

    public func allSessionsInfo() -> [(id: String, sourceFile: URL)] {
        sessions.map { ($0.key, $0.value.sourceFile) }
    }

    private func republish() async {
        guard let registry else { return }
        let snapshot = sessions.map {
            ($0.key, $0.value.sourceFile, $0.value.deviceUDID as String?)
        }
        await registry.publishIOSSessions(snapshot)
    }
}

import Foundation
import PreviewsCore
import PreviewsIOS

/// Tracks active iOS preview sessions and lazily creates shared iOS
/// resources (compiler, host builder). One instance is shared across
/// all daemon connections so sessions persist across CLI invocations.
public actor IOSSessionManager {
    public let simulatorManager = SimulatorManager()
    private var compiler: Compiler?
    private var hostBuilder: IOSHostBuilder?
    private var sessions: [String: IOSPreviewSession] = [:]
    private var fileWatchers: [String: FileWatcher] = [:]
    /// Cross-process session registry. When attached, every mutation
    /// republishes the current iOS session set so peer processes see
    /// our sessions in their `session_list` output.
    private var registry: SessionRegistry?

    public init() {}

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

    public func getHostBuilder() async throws -> IOSHostBuilder {
        if let b = hostBuilder { return b }
        let b = try await IOSHostBuilder()
        hostBuilder = b
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
        sessions.removeValue(forKey: id)
        fileWatchers[id]?.stop()
        fileWatchers.removeValue(forKey: id)
        await republish()
    }

    public func setFileWatcher(_ id: String, _ watcher: FileWatcher) {
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
        let snapshot = sessions.map { ($0.key, $0.value.sourceFile) }
        await registry.publishIOSSessions(snapshot)
    }
}

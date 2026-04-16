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

    public init() {}

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

    public func addSession(_ session: IOSPreviewSession) {
        sessions[session.id] = session
    }

    public func getSession(_ id: String) -> IOSPreviewSession? {
        sessions[id]
    }

    public func removeSession(_ id: String) {
        sessions.removeValue(forKey: id)
        fileWatchers[id]?.stop()
        fileWatchers.removeValue(forKey: id)
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
}

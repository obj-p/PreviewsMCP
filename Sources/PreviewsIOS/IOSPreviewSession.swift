import Foundation
import PreviewsCore

/// Orchestrates the full iOS preview pipeline:
/// boot simulator → install host app → compile dylib → launch → screenshot.
public actor IOSPreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public nonisolated let previewIndex: Int
    public nonisolated let deviceUDID: String

    private let compiler: Compiler
    private let hostBuilder: IOSHostBuilder
    private let simulatorManager: SimulatorManager

    private var signalFilePath: URL?
    private var literalsFilePath: URL?
    private var session: PreviewSession?

    public static let hostBundleID = "com.previews-mcp.ios-host"

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        deviceUDID: String,
        compiler: Compiler,
        hostBuilder: IOSHostBuilder,
        simulatorManager: SimulatorManager
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.deviceUDID = deviceUDID
        self.compiler = compiler
        self.hostBuilder = hostBuilder
        self.simulatorManager = simulatorManager
    }

    /// Start the iOS preview: compile, boot sim, install host, launch.
    /// Returns the PID of the launched host app.
    public func start() async throws -> Int {
        // 1. Compile preview dylib for iOS simulator
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOSSimulator
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        // 2. Boot simulator and install host app.
        // Retry loop handles transient CoreSimulator daemon issues
        // (Mach error -308, "Shutdown" state races from concurrent operations).
        let appPath = try await hostBuilder.ensureHostApp()
        var lastError: Error?
        for attempt in 1...3 {
            do {
                // Check/boot on every attempt — device may have been shut down externally
                let device = try await simulatorManager.findDevice(udid: deviceUDID)
                if device.state != .booted {
                    try await simulatorManager.bootDevice(udid: deviceUDID)
                    try await Task.sleep(for: .seconds(5))
                }
                try await simulatorManager.installApp(udid: deviceUDID, appPath: appPath.path)
                lastError = nil
                break
            } catch {
                lastError = error
                if attempt < 3 {
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
        if let lastError { throw lastError }

        // 4. Create signal files for hot-reload
        let workDir = compileResult.dylibPath.deletingLastPathComponent()
        let signalFile = workDir.appendingPathComponent("reload-signal.txt")
        let literalsFile = workDir.appendingPathComponent("literals-signal.json")
        try compileResult.dylibPath.path.write(to: signalFile, atomically: true, encoding: .utf8)
        try "[]".write(to: literalsFile, atomically: true, encoding: .utf8)
        signalFilePath = signalFile
        literalsFilePath = literalsFile

        // 5. Launch host app with dylib path
        let pid = try await simulatorManager.launchApp(
            udid: deviceUDID,
            bundleID: Self.hostBundleID,
            arguments: [
                "--dylib", compileResult.dylibPath.path,
                "--signal-file", signalFile.path,
                "--literals-file", literalsFile.path,
            ]
        )

        return pid
    }

    /// Handle a source file change. Tries the literal fast path first;
    /// falls back to full recompile if structural changes are detected.
    /// Returns true if the fast path was used.
    @discardableResult
    public func handleSourceChange() async throws -> Bool {
        guard signalFilePath != nil else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)

        // Fast path: literal-only change
        if let currentSession = session,
           let changes = await currentSession.tryLiteralUpdate(newSource: newSource),
           !changes.isEmpty,
           let literalsFile = literalsFilePath {
            let json = changes.map { change -> [String: Any] in
                var entry: [String: Any] = ["id": change.id]
                switch change.newValue {
                case .string(let s):
                    entry["type"] = "string"
                    entry["value"] = s
                case .integer(let n):
                    entry["type"] = "integer"
                    entry["value"] = n
                case .float(let d):
                    entry["type"] = "float"
                    entry["value"] = d
                case .boolean(let b):
                    entry["type"] = "boolean"
                    entry["value"] = b
                }
                return entry
            }
            let data = try JSONSerialization.data(withJSONObject: json)
            try data.write(to: literalsFile, options: .atomic)
            return true
        }

        // Slow path: structural change, full recompile
        try await reload()
        return false
    }

    /// Recompile the preview and signal the running host app to reload.
    public func reload() async throws {
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOSSimulator
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        guard let signalFile = signalFilePath else {
            throw IOSPreviewSessionError.notStarted
        }
        try compileResult.dylibPath.path.write(to: signalFile, atomically: true, encoding: .utf8)
    }

    /// Capture a screenshot of the simulator.
    public func screenshot() async throws -> Data {
        return try await simulatorManager.screenshotData(udid: deviceUDID)
    }
}

public enum IOSPreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case notStarted

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        }
    }

    public var errorDescription: String? { description }
}

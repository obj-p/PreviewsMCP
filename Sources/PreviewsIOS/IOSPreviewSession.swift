import Foundation
import PreviewsCore

/// Orchestrates the full iOS preview pipeline:
/// boot simulator → install host app → compile dylib → launch → screenshot.
///
/// Communicates with the iOS host app over a TCP loopback socket (127.0.0.1).
/// See docs/communication-protocol.md for protocol details.
public actor IOSPreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public private(set) var previewIndex: Int
    public nonisolated let deviceUDID: String

    private let compiler: Compiler
    private let hostBuilder: IOSHostBuilder
    private let simulatorManager: SimulatorManager
    private let progress: (any ProgressReporter)?

    private var session: PreviewSession?
    public nonisolated let headless: Bool
    private let buildContext: BuildContext?
    private var traits: PreviewTraits
    private let setupModule: String?
    private let setupType: String?
    private let setupCompilerFlags: [String]
    private let setupDylibPath: URL?
    public var currentTraits: PreviewTraits { traits }

    /// Transport to the iOS host app. Owns all socket state — bind,
    /// accept, line-delimited JSON send/receive, lifecycle. Constructed
    /// per-session and torn down by `stop()`.
    private let channel = IOSHostChannel()

    public static let hostBundleID = "com.previewsmcp.host"

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        deviceUDID: String,
        compiler: Compiler,
        hostBuilder: IOSHostBuilder,
        simulatorManager: SimulatorManager,
        headless: Bool = true,
        buildContext: BuildContext? = nil,
        traits: PreviewTraits = PreviewTraits(),
        setupModule: String? = nil,
        setupType: String? = nil,
        setupCompilerFlags: [String] = [],
        setupDylibPath: URL? = nil,
        progress: (any ProgressReporter)? = nil
    ) {
        self.id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.deviceUDID = deviceUDID
        self.compiler = compiler
        self.hostBuilder = hostBuilder
        self.simulatorManager = simulatorManager
        self.headless = headless
        self.buildContext = buildContext
        self.traits = traits
        self.setupModule = setupModule
        self.setupType = setupType
        self.setupCompilerFlags = setupCompilerFlags
        self.setupDylibPath = setupDylibPath
        self.progress = progress
    }

    // MARK: - Lifecycle

    /// Start the iOS preview: compile, boot sim, install host, launch, connect socket.
    /// Returns the PID of the launched host app.
    public func start() async throws -> Int {
        // Mirror stage transitions to the diagnostic log so operators
        // running `previewsmcp logs` (or scraping CI capture files) can
        // see where a stall occurred. MCP LogMessageNotifications go
        // over stdout and aren't visible unless the client subscribes;
        // stderr is always captured by the parent process. Kept terse.
        func stage(_ s: String) {
            Log.info("iOS preview: \(s) [\(deviceUDID.prefix(8))]")
        }

        // 1. Compile preview dylib for iOS simulator
        stage("compiling dylib")
        await progress?.report(.compilingBridge, message: "Compiling \(sourceFile.lastPathComponent)...")
        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOS,
            buildContext: buildContext,
            traits: traits,
            setupModule: setupModule,
            setupType: setupType,
            setupCompilerFlags: setupCompilerFlags
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        // 2. Build host app.
        stage("building host app")
        await progress?.report(.compilingHostApp, message: "Building iOS host app...")
        let appPath = try await hostBuilder.ensureHostApp()
        stage("host app ready")

        // 4. Create TCP server on loopback, bind to ephemeral port
        let port = try await channel.bindAndListen()

        // 5. Boot + install + launch with retry. The whole sequence is
        // retried because PR #141 CI has shown the iOS simulator
        // occasionally getting into an "intermediate-booted" state
        // where bootstatus reports booted but launchApp hangs. Simply
        // retrying the launch doesn't help — we need to shutdown the
        // device and reboot to get a clean state. Hence the full
        // boot→install→launch cycle inside the retry loop, with a
        // shutdown between attempts.
        await progress?.report(.bootingSimulator, message: "Booting simulator (\(deviceUDID.prefix(8))...)...")
        await progress?.report(.installingApp, message: "Installing host app...")
        await progress?.report(.launchingApp, message: "Launching host app...")

        var launchArgs = [
            "--dylib", compileResult.dylibPath.path,
            "--port", String(port),
        ]
        if let setupPath = setupDylibPath {
            launchArgs += ["--setup-dylib", setupPath.path]
        }

        var launchedPid: Int?
        var lastError: Error?
        for attempt in 1...3 {
            do {
                stage("boot/install/launch attempt \(attempt)/3")
                let device = try await simulatorManager.findDevice(udid: deviceUDID)
                if device.state != .booted {
                    stage("attempt \(attempt): bootDevice")
                    try await simulatorManager.bootDevice(udid: deviceUDID)
                    stage("attempt \(attempt): boot complete")
                } else {
                    stage("attempt \(attempt): already booted")
                }
                stage("attempt \(attempt): installApp")
                try await simulatorManager.installApp(udid: deviceUDID, appPath: appPath.path)
                stage("attempt \(attempt): install ok")

                // Open Simulator.app GUI if not headless (only on successful
                // path; no point opening the GUI for a failing retry).
                if !headless {
                    _ = try? await runAsync(
                        "/usr/bin/open",
                        arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", deviceUDID]
                    )
                }

                // Terminate any stale host instance first (orphan from a
                // prior test or retry). simctl terminate is a no-op when
                // the app isn't running and bounds any hang at 30s.
                stage("attempt \(attempt): pre-launch terminate stale host")
                await simulatorManager.terminateAppIfRunning(
                    udid: deviceUDID, bundleID: Self.hostBundleID)

                stage("attempt \(attempt): launching host app")
                launchedPid = try await simulatorManager.launchApp(
                    udid: deviceUDID,
                    bundleID: Self.hostBundleID,
                    arguments: launchArgs
                )
                lastError = nil
                break
            } catch {
                stage("attempt \(attempt) failed: \(error)")
                lastError = error
                if attempt < 3 {
                    // Shut down the device to clear any stuck kernel/backend
                    // state before the next boot attempt. Best-effort — if
                    // shutdown itself fails or hangs, the next findDevice +
                    // bootDevice will handle whatever state we end up in.
                    stage("attempt \(attempt): shutting down for clean reboot")
                    try? await simulatorManager.shutdownDevice(udid: deviceUDID)
                    try await Task.sleep(for: .seconds(3))
                }
            }
        }
        if let lastError { throw lastError }
        guard let pid = launchedPid else { throw lastError ?? IOSPreviewSessionError.socketCreateFailed }

        // 6. Accept connection from host app (up to 10 seconds)
        stage("launched pid=\(pid); awaiting socket connection")
        await progress?.report(.connectingToApp, message: "Waiting for host app connection...")
        try await channel.awaitConnect(timeout: .seconds(10))
        stage("connected; start complete")

        return pid
    }

    /// Close the socket connection and clean up resources. Idempotent —
    /// `IOSHostChannel.close()` is safe to call when nothing was opened.
    public func stop() async {
        await channel.close()
    }

    // MARK: - Communication

    /// Recompile the preview and signal the host app to reload via socket.
    /// Waits for reloadAck to ensure SwiftUI environment has propagated.
    public func reload() async throws {
        guard await channel.isConnected else {
            throw IOSPreviewSessionError.notStarted
        }

        let previewSession = PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOS,
            buildContext: buildContext,
            traits: traits,
            setupModule: setupModule,
            setupType: setupType,
            setupCompilerFlags: setupCompilerFlags
        )
        self.session = previewSession
        let compileResult = try await previewSession.compile()

        let requestID = UUID().uuidString
        _ = try await channel.sendAndAwait(
            ["type": "reload", "id": requestID, "dylibPath": compileResult.dylibPath.path],
            id: requestID,
            timeout: .seconds(5)
        )
    }

    /// Handle a source file change. Tries the literal fast path first;
    /// falls back to full recompile if structural changes are detected.
    @discardableResult
    public func handleSourceChange() async throws -> Bool {
        guard await channel.isConnected else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)

        // Fast path: literal-only change
        if let currentSession = session,
            let changes = await currentSession.tryLiteralUpdate(newSource: newSource),
            !changes.isEmpty
        {
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
            await channel.send(["type": "literals", "changes": json])
            return true
        }

        // Slow path: structural change, full recompile
        try await reload()
        return false
    }

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreview(to newIndex: Int) async throws {
        let oldIndex = self.previewIndex
        self.previewIndex = newIndex
        do {
            try await reload()
        } catch {
            self.previewIndex = oldIndex
            throw error
        }
    }

    /// Update traits and recompile. Signals the host app to reload. @State is lost.
    ///
    /// See `PreviewSession.reconfigure(traits:clearing:)` for the semantics
    /// of `clearing`.
    public func reconfigure(
        traits: PreviewTraits,
        clearing: Set<PreviewTraits.Field> = []
    ) async throws {
        self.traits = self.traits.merged(with: traits).clearing(clearing)
        try await reload()
    }

    /// Replace traits entirely (no merge) and recompile. Used by preview_variants.
    public func setTraits(_ newTraits: PreviewTraits) async throws {
        self.traits = newTraits
        try await reload()
    }

    /// Send a tap at the given point coordinates (in device points).
    public func sendTap(x: Double, y: Double) async throws {
        await channel.send(["type": "touch", "action": "tap", "x": x, "y": y])
        try await Task.sleep(for: .milliseconds(250))
    }

    /// Send a swipe gesture from one point to another.
    public func sendSwipe(
        fromX: Double, fromY: Double,
        toX: Double, toY: Double,
        duration: Double = 0.3,
        steps: Int = 10
    ) async throws {
        await channel.send([
            "type": "touch",
            "action": "swipe",
            "fromX": fromX, "fromY": fromY,
            "toX": toX, "toY": toY,
            "duration": duration, "steps": steps,
        ])
        try await Task.sleep(for: .milliseconds(Int(duration * 1000) + 200))
    }

    /// Fetch the accessibility tree from the running preview.
    /// - Parameter filter: Filter mode: "all" (default), "interactable", or "labeled"
    public func fetchElements(filter: String = "all") async throws -> String {
        guard await channel.isConnected else {
            throw IOSPreviewSessionError.notStarted
        }

        let requestID = UUID().uuidString
        let responseData = try await channel.sendAndAwait(
            ["type": "elements", "id": requestID, "filter": filter],
            id: requestID,
            timeout: .seconds(3)
        )

        guard let response = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let tree = response["tree"] as? [String: Any]
        else {
            throw IOSPreviewSessionError.socketResponseTimeout("elementsResponse")
        }

        // Apply server-side filtering if needed
        let resultTree: [String: Any]
        if filter != "all", let filtered = filterTree(tree, mode: filter) {
            resultTree = filtered
        } else {
            resultTree = tree
        }

        let data = try JSONSerialization.data(withJSONObject: resultTree)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Capture a screenshot of the simulator.
    public func screenshot(jpegQuality: Double = 0.85) async throws -> Data {
        return try await simulatorManager.screenshotData(udid: deviceUDID, jpegQuality: jpegQuality)
    }

    // MARK: - Accessibility tree filtering

    private func filterTree(_ node: [String: Any], mode: String) -> [String: Any]? {
        guard let children = node["children"] as? [[String: Any]], !children.isEmpty else {
            return matchesFilter(node, mode: mode) ? node : nil
        }

        var filteredChildren: [[String: Any]] = []
        for child in children {
            if let filtered = filterTree(child, mode: mode) {
                filteredChildren.append(filtered)
            }
        }

        guard !filteredChildren.isEmpty else { return nil }

        var result = node
        result["children"] = filteredChildren
        return result
    }

    private func matchesFilter(_ node: [String: Any], mode: String) -> Bool {
        switch mode {
        case "interactable":
            guard let traits = node["traits"] as? [String] else { return false }
            let interactableTraits: Set<String> = ["button", "link", "adjustable", "searchField"]
            return traits.contains(where: { interactableTraits.contains($0) })
        case "labeled":
            if let label = node["label"] as? String, !label.isEmpty { return true }
            if let value = node["value"] as? String, !value.isEmpty { return true }
            if let identifier = node["identifier"] as? String, !identifier.isEmpty { return true }
            return false
        default:
            return true
        }
    }
}

public enum IOSPreviewSessionError: Error, LocalizedError, CustomStringConvertible {
    case notStarted
    case socketCreateFailed
    case socketAcceptFailed
    case socketAcceptTimeout
    case socketResponseTimeout(String)
    case connectionLost

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        case .socketCreateFailed: return "Failed to create TCP server socket"
        case .socketAcceptFailed: return "Failed to accept connection from host app"
        case .socketAcceptTimeout: return "Timed out waiting for host app to connect"
        case .socketResponseTimeout(let id): return "Timed out waiting for response (id: \(id))"
        case .connectionLost: return "Connection to host app lost"
        }
    }

    public var errorDescription: String? { description }
}

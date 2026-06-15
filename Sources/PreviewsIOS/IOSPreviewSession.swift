import Darwin
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
    private let setupSDKPath: String?
    private let setupDylibPath: URL?
    public var currentTraits: PreviewTraits { traits }

    /// Transport to the iOS host app. Owns all socket state — bind,
    /// accept, line-delimited JSON send/receive, lifecycle. Constructed
    /// per-session and torn down by `stop()`.
    private let channel = IOSHostChannel()

    /// Builds the JIT reloader from the accepted EPC socket and the bundled
    /// iossim orc runtime path. Injected by the composition root behind the JIT
    /// flag; `nil` keeps the session on the dylib path.
    public typealias MakeJITReloader =
        @Sendable (_ epcFD: Int32, _ orcRuntimePath: String) throws -> any IOSStructuralReloader
    private let makeJITReloader: MakeJITReloader?
    private var jitReloader: (any IOSStructuralReloader)?
    private var jitListenFD: Int32 = -1

    /// Outermost body kind of the currently-loaded preview. Reported by the host
    /// after each dylib load (initial `init` handshake + every `reloadAck`).
    /// Defaults to `.uiView` so a stale or legacy host that never reports a kind
    /// keeps the daemon on the safe full-reload path — never silently no-ops the
    /// way the literal-only fast path did before #160.
    private var lastBodyKind: BodyKind = .uiView

    /// Test-only window into the body-kind state set by the `init` handshake
    /// and each `reloadAck`. Production callers gate via `handleSourceChange`
    /// — they don't need direct access.
    public var currentBodyKind: BodyKind { lastBodyKind }

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
        setupSDKPath: String? = nil,
        setupDylibPath: URL? = nil,
        progress: (any ProgressReporter)? = nil,
        makeJITReloader: MakeJITReloader? = nil
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
        self.setupSDKPath = setupSDKPath
        self.setupDylibPath = setupDylibPath
        self.progress = progress
        self.makeJITReloader = makeJITReloader
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

        var jitMode = false
        #if PREVIEWSMCP_IOS_JIT
        jitMode = makeJITReloader != nil
        #endif

        // 1. Compile the preview. The dylib path links a dylib now and loads it via
        // the host's `--dylib` argv; the JIT path skips the dylib and renders over the
        // EPC connection once the in-app executor is up (step 8).
        stage(jitMode ? "compiling (JIT)" : "compiling dylib")
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
            setupCompilerFlags: setupCompilerFlags,
            setupSDKPath: setupSDKPath
        )
        self.session = previewSession
        let dylibPath = jitMode ? nil : try await previewSession.compile().dylibPath

        // 2. Build host app.
        stage("building host app")
        await progress?.report(.compilingHostApp, message: "Building iOS host app...")
        let appPath = try await hostBuilder.ensureHostApp()
        stage("host app ready")

        // 4. Create TCP server on loopback, bind to ephemeral port
        let port = try await channel.bindAndListen()

        // 4b. JIT mode: bind a second loopback listener for the EPC channel the
        // in-app ORC executor connects back on. The JSON channel above still
        // serves elements / touch / screenshot.
        var jitPort: Int?
        #if PREVIEWSMCP_IOS_JIT
        if makeJITReloader != nil {
            jitPort = try bindJITListener()
        }
        #endif

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

        var launchArgs = ["--port", String(port)]
        if let dylibPath {
            launchArgs += ["--dylib", dylibPath.path]
        }
        if let setupPath = setupDylibPath {
            launchArgs += ["--setup-dylib", setupPath.path]
        }
        if let jitPort {
            launchArgs += ["--jit-port", String(jitPort)]
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

        // 7. Body-kind handshake (#160). The first dylib is loaded via the host's
        // `--dylib` argv (no `reload` round-trip), so the daemon would otherwise
        // not learn the body kind until the first edit forces a reload — meaning
        // a SwiftUI session would pay one extra full recompile on its very first
        // literal edit. Asking the host upfront eliminates that cost. A 2s
        // timeout is generous: the host has nothing to do but call dlsym and
        // reply. If the request times out (legacy host, missing symbol),
        // `lastBodyKind` stays at its safe default of `.uiView`.
        do {
            let initID = "init-\(UUID().uuidString)"
            let responseData = try await channel.sendAndAwait(
                ["type": "init", "id": initID],
                id: initID,
                timeout: .seconds(2)
            )
            if let dict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
                let kind = dict["kind"] as? String,
                let parsed = BodyKind(wireValue: kind)
            {
                lastBodyKind = parsed
            }
        } catch {
            // Legacy host or transient hiccup — keep the safe default.
            // Log at info so users debugging an unexpected full-reload-on-every-edit
            // can spot the missed handshake without grepping for "stage" details.
            Log.info(
                "iOS preview: body-kind handshake skipped (\(error)); assuming legacy host, defaulting lastBodyKind=.uiView"
            )
        }

        #if PREVIEWSMCP_IOS_JIT
        // 8. JIT mode: accept the executor's EPC connection and stand up the
        // remote session over it. The host connects --port and --jit-port
        // independently, so this accept is ordered after the JSON connect but
        // either may arrive first (the listen backlog holds the other).
        if let make = makeJITReloader {
            guard let orcPath = IOSHostBuilder.jitOrcRuntimePath else {
                throw IOSPreviewSessionError.jitRuntimeMissing
            }
            stage("awaiting JIT executor connection")
            let epcFD = try acceptJIT(timeoutSeconds: 10)
            let reloader = try make(epcFD, orcPath)
            jitReloader = reloader
            stage("JIT executor connected; rendering initial preview")
            let build = try await previewSession.compileObjectForJIT()
            try await reloader.render(build)
            stage("initial JIT render complete")
        }
        #endif

        stage("connected; start complete (bodyKind=\(lastBodyKind))")

        return pid
    }

    /// Close the socket connection and clean up resources. Idempotent —
    /// `IOSHostChannel.close()` is safe to call when nothing was opened.
    public func stop() async {
        await channel.close()
        jitReloader = nil
        if jitListenFD >= 0 {
            Darwin.close(jitListenFD)
            jitListenFD = -1
        }
    }

    // MARK: - JIT EPC socket

    /// Bind a second loopback listener for the in-app ORC executor's EPC
    /// connection and return the assigned port. The accepted fd is owned by the
    /// JIT session built from it; `stop()` closes the listen fd.
    private func bindJITListener() throws -> Int {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw IOSPreviewSessionError.socketCreateFailed }
        var reuse: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                Darwin.bind(fd, sockPtr, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, Darwin.listen(fd, 1) == 0 else {
            Darwin.close(fd)
            throw IOSPreviewSessionError.socketCreateFailed
        }

        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &name) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockPtr in
                getsockname(fd, sockPtr, &len)
            }
        }
        guard named == 0 else {
            Darwin.close(fd)
            throw IOSPreviewSessionError.socketCreateFailed
        }
        jitListenFD = fd
        return Int(UInt16(bigEndian: name.sin_port))
    }

    /// Accept the executor's EPC connection (up to `timeoutSeconds`) and close
    /// the listen fd. Returns the connected fd, which the JIT session owns.
    private func acceptJIT(timeoutSeconds: Int32) throws -> Int32 {
        var pfd = pollfd(fd: jitListenFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutSeconds * 1000)
        guard ready > 0 else {
            throw IOSPreviewSessionError.socketAcceptTimeout
        }
        let conn = Darwin.accept(jitListenFD, nil, nil)
        Darwin.close(jitListenFD)
        jitListenFD = -1
        guard conn >= 0 else {
            throw IOSPreviewSessionError.socketAcceptFailed
        }
        return conn
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
            setupCompilerFlags: setupCompilerFlags,
            setupSDKPath: setupSDKPath
        )
        self.session = previewSession

        #if PREVIEWSMCP_IOS_JIT
        // JIT path: link the freshly compiled object into the live host over EPC and
        // re-run its render entry. No dylib, no `reload` round-trip over the JSON channel.
        if let jitReloader {
            let build = try await previewSession.compileObjectForJIT()
            try await jitReloader.render(build)
            return
        }
        #endif

        let compileResult = try await previewSession.compile()

        let requestID = UUID().uuidString
        let responseData = try await channel.sendAndAwait(
            ["type": "reload", "id": requestID, "dylibPath": compileResult.dylibPath.path],
            id: requestID,
            timeout: .seconds(5)
        )
        // Re-read the body kind from the just-loaded dylib. Reloads can change
        // the kind (e.g., after `preview_switch` to a different `#Preview` block,
        // or after a structural edit that changes the body's outermost type).
        // A missing `kind` field falls back to the previous value rather than
        // the default, so a one-off ack-shape regression doesn't suddenly start
        // forcing reloads on a SwiftUI session.
        if let dict = try? JSONSerialization.jsonObject(with: responseData) as? [String: Any],
            let kind = dict["kind"] as? String,
            let parsed = BodyKind(wireValue: kind)
        {
            lastBodyKind = parsed
        }
    }

    /// Handle a source file change. Tries the literal fast path first;
    /// falls back to full recompile if structural changes are detected.
    @discardableResult
    public func handleSourceChange() async throws -> Bool {
        guard await channel.isConnected else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)

        // Fast path: literal-only change. Only safe for SwiftUI bodies — the
        // path mutates `DesignTimeStore.shared.values` and relies on
        // `@Observable` to drive a re-render, which UIKit doesn't do (#160).
        // Mixed bodies (SwiftUI outermost, UIKit `UIViewRepresentable` deeper
        // in the file) are handled separately by `LiteralDiffer`'s region
        // taint check — it returns `.structural` if any edited literal lives
        // in a UIKit-evaluated scope, so `tryLiteralUpdate` returns nil here.
        if lastBodyKind == .swiftUI,
            let currentSession = session,
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
            throw IOSPreviewSessionError.responseDecodeFailed(operation: "elements")
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
    case jitRuntimeMissing
    case socketResponseTimeout(String)
    case connectionLost
    /// JSON parse or shape mismatch on a host-app response. Distinct
    /// from `socketResponseTimeout` so callers and operators can tell
    /// "host app didn't respond" from "host app responded with garbage."
    case responseDecodeFailed(operation: String)

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        case .socketCreateFailed: return "Failed to create TCP server socket"
        case .socketAcceptFailed: return "Failed to accept connection from host app"
        case .socketAcceptTimeout: return "Timed out waiting for host app to connect"
        case .jitRuntimeMissing: return "Bundled iossim orc runtime archive not found"
        case .socketResponseTimeout(let id): return "Timed out waiting for response (id: \(id))"
        case .connectionLost: return "Connection to host app lost"
        case .responseDecodeFailed(let operation):
            return "Failed to decode host app response (operation: \(operation))"
        }
    }

    public var errorDescription: String? { description }
}

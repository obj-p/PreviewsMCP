import Darwin
import Foundation
import PreviewsCore
@preconcurrency import SimulatorBridge

/// Orchestrates the full iOS preview pipeline:
/// boot simulator → install agent app → compile object → launch → JIT-link + render.
///
/// Drives the agent app over two TCP loopback sockets (127.0.0.1): a JSON channel
/// for touch / elements, and the JIT EPC channel that links each compiled preview
/// object into the in-app ORC executor. See docs/communication-protocol.md.
public actor IOSPreviewSession {
    public nonisolated let id: String
    public nonisolated let sourceFile: URL
    public private(set) var previewIndex: Int
    public nonisolated let deviceUDID: String

    private let compiler: Compiler
    private let agentBuilder: IOSAgentBuilder
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
    public var currentTraits: PreviewTraits {
        traits
    }

    /// Transport to the iOS agent app. Owns all socket state — bind,
    /// accept, line-delimited JSON send/receive, lifecycle. Constructed
    /// per-session and torn down by `stop()`.
    private let channel = IOSAgentChannel()

    /// Builds the JIT reloader from the accepted EPC socket and the bundled
    /// iossim orc runtime path. Injected by the composition root so every
    /// session has a reloader; tests supply their own factory.
    public typealias MakeJITReloader =
        @Sendable (_ epcFD: Int32, _ orcRuntimePath: String) throws -> any IOSStructuralReloader
    private let makeJITReloader: MakeJITReloader
    private var jitReloader: (any IOSStructuralReloader)?
    private var jitListenFD: Int32 = -1

    /// `stop()` was called — suppress the death watcher so an intentional
    /// teardown never respawns. `isRelaunching` is true for the duration of a
    /// planned `_relaunch()` (memory-cap or recovery) so its own host-termination
    /// EOF does not re-trigger the watcher. `recovering` coalesces concurrent
    /// death callbacks into one respawn. See issue #253.
    private var stopping = false
    private var isRelaunching = false
    private var recovering = false

    public static let agentBundleID = "com.previewsmcp.agent"
    public static let shellBundleID = "com.previewsmcp.shell"

    private static func agentLaunchArgs(port: Int, jitPort: Int, agentSockPath: String) -> [String] {
        ["--port", String(port), "--jit-port", String(jitPort), "--agent-sock", agentSockPath]
    }

    public init(
        sourceFile: URL,
        previewIndex: Int = 0,
        deviceUDID: String,
        compiler: Compiler,
        agentBuilder: IOSAgentBuilder,
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
        makeJITReloader: @escaping MakeJITReloader
    ) {
        id = UUID().uuidString
        self.sourceFile = sourceFile
        self.previewIndex = previewIndex
        self.deviceUDID = deviceUDID
        self.compiler = compiler
        self.agentBuilder = agentBuilder
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

    /// Stable agent handshake socket path, set at `start()` and reused across
    /// respawns so the long-lived shell reconnects to the same path the new
    /// agent rebinds (the shell is never relaunched).
    private var agentSockPath: String?

    /// Per-session app interface (loopback stream + control). Hosted here so it
    /// captures the display in-process and survives agent respawn (it targets
    /// the device, not the agent process).
    private var appServer: PreviewAppServer?
    private var appFrameSource: EventDrivenFrameSource?
    private var appVideoStream: AVCCVideoStream?
    public private(set) var appServerPort: UInt16?

    /// Serializes the mutating render entry points (`reload`, `handleSourceChange`). The file
    /// watcher fires a Task per change, so without this two edits could interleave at an
    /// `await` and one could render or relaunch while the other has the channel torn down.
    private var renderBusy = false
    private var renderWaiters: [CheckedContinuation<Void, Never>] = []

    private func acquireRenderLock() async {
        if !renderBusy {
            renderBusy = true
            return
        }
        await withCheckedContinuation { renderWaiters.append($0) }
    }

    private func releaseRenderLock() {
        if renderWaiters.isEmpty {
            renderBusy = false
        } else {
            renderWaiters.removeFirst().resume()
        }
    }

    // MARK: - Lifecycle

    /// Start the iOS preview: compile, boot sim, install host, launch, connect socket.
    /// Returns the PID of the launched agent app.
    public func start() async throws -> Int {
        guard let orcPath = IOSAgentBuilder.jitOrcRuntimePath else {
            throw IOSPreviewSessionError.jitRuntimeMissing
        }

        // Fail fast on pre-iOS-26 runtimes: the shell hosts the agent's scene via
        // a private initializer that only exists on iOS 26, so on older runtimes
        // hosting is impossible and every captured frame is the springboard, not
        // the preview (#282). Refuse with a clear diagnostic instead.
        let device = try await simulatorManager.findDevice(udid: deviceUDID)
        if !device.isPreviewSupported {
            throw IOSPreviewSessionError.unsupportedRuntime(
                device.runtimeName ?? device.iosMajorVersion.map { "iOS \($0)" } ?? "this simulator"
            )
        }

        /// Mirror stage transitions to the diagnostic log so operators
        /// running `previewsmcp logs` (or scraping CI capture files) can
        /// see where a stall occurred. MCP LogMessageNotifications go
        /// over stdout and aren't visible unless the client subscribes;
        /// stderr is always captured by the parent process. Kept terse.
        func stage(_ s: String) {
            Log.info("iOS preview: \(s) [\(deviceUDID.prefix(8))]")
        }

        // 1. Compile the preview to an object. JIT links it into the in-app
        // executor over the EPC connection once the executor is up (step 8);
        // there is no preview dylib.
        stage("compiling (JIT)")
        await progress?.report(.compilingBridge, message: "Compiling \(sourceFile.lastPathComponent)...")
        let previewSession = makePreviewSession()
        session = previewSession

        // 2. Build host (agent) app and the foreground shell app that hosts
        // its cross-process scene.
        stage("building agent app")
        await progress?.report(.compilingAgentApp, message: "Building iOS agent app...")
        async let agentBuild = agentBuilder.ensureAgentApp()
        async let shellBuild = agentBuilder.ensureShellApp()
        let appPath = try await agentBuild
        let shellPath = try await shellBuild
        stage("agent app ready")

        // 4. Create TCP server on loopback, bind to ephemeral port
        let port = try await channel.bindAndListen()

        // 4b. Bind a second loopback listener for the EPC channel the in-app ORC
        // executor connects back on. The JSON channel above still serves
        // elements / touch / screenshot.
        let jitPort = try bindJITListener()

        // 5. Boot + install + launch with retry. The whole sequence is
        // retried because PR #141 CI has shown the iOS simulator
        // occasionally getting into an "intermediate-booted" state
        // where bootstatus reports booted but launchApp hangs. Simply
        // retrying the launch doesn't help — we need to shutdown the
        // device and reboot to get a clean state. Hence the full
        // boot→install→launch cycle inside the retry loop, with a
        // shutdown between attempts.
        await progress?.report(.bootingSimulator, message: "Booting simulator (\(deviceUDID.prefix(8))...)...")
        await progress?.report(.installingApp, message: "Installing agent app...")
        await progress?.report(.launchingApp, message: "Launching agent app...")

        // The agent binds this Unix-domain socket; the shell connects to it to
        // read the agent's audit token for the hosting handshake. It lives in
        // the simulator's shared /tmp, keyed by port so concurrent sessions on
        // one simulator don't collide.
        let agentSockPath = "/tmp/previewsmcp-agent-\(port).sock"
        self.agentSockPath = agentSockPath
        let launchArgs = Self.agentLaunchArgs(port: port, jitPort: jitPort, agentSockPath: agentSockPath)

        var launchedPid: Int?
        var lastError: Error?
        for attempt in 1 ... 3 {
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
                try await simulatorManager.installApp(udid: deviceUDID, appPath: shellPath.path)
                stage("attempt \(attempt): install ok")

                // Open Simulator.app GUI if not headless (only on successful
                // path; no point opening the GUI for a failing retry).
                if !headless {
                    _ = try? await runAsync(
                        "/usr/bin/open",
                        arguments: ["-a", "Simulator", "--args", "-CurrentDeviceUDID", deviceUDID]
                    )
                }

                // Terminate any stale agent instance first (orphan from a
                // prior test or retry). simctl terminate is a no-op when
                // the app isn't running and bounds any hang at 30s.
                stage("attempt \(attempt): pre-launch terminate stale agent + shell")
                await simulatorManager.terminateAppIfRunning(
                    udid: deviceUDID, bundleID: Self.shellBundleID
                )
                await simulatorManager.terminateAppIfRunning(
                    udid: deviceUDID, bundleID: Self.agentBundleID
                )

                // Shell first, agent second (#352). The shell's foreground
                // transition then originates from SpringBoard, not from the
                // agent, so the status bar never shows a "< Agent" back-
                // breadcrumb. The shell retries the agent-UDS connect until
                // the agent binds it, so launching it before the agent is
                // safe. The agent launches with activate_suspended and never
                // takes the foreground at all — which also removes the
                // transient agent-active flash on every launch.
                stage("attempt \(attempt): launching shell app")
                _ = try await simulatorManager.launchApp(
                    udid: deviceUDID,
                    bundleID: Self.shellBundleID,
                    arguments: ["--agent-sock", agentSockPath]
                )
                stage("attempt \(attempt): launching agent app (background)")
                launchedPid = try await simulatorManager.launchAppInBackground(
                    udid: deviceUDID,
                    bundleID: Self.agentBundleID,
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

        // 6. Accept connection from agent app (up to 10 seconds). This also
        // confirms the agent's didFinishLaunchingWithOptions has run, so its
        // handshake socket is bound; the already-running shell's UDS retry
        // loop connects to it, reads the agent's audit token, and routes the
        // cross-process hosted scene back to the agent. The shell is
        // long-lived and survives agent respawns (no relaunch flash).
        stage("launched pid=\(pid); awaiting socket connection")
        await progress?.report(.connectingToApp, message: "Waiting for agent app connection...")
        try await channel.awaitConnect(timeout: .seconds(10))

        // 8. Accept the executor's EPC connection and stand up the remote session
        // over it. The host connects --port and --jit-port independently, so this
        // accept is ordered after the JSON connect but either may arrive first
        // (the listen backlog holds the other).
        stage("awaiting JIT executor connection")
        do {
            let epcFD = try acceptJIT(timeoutSeconds: 10)
            let reloader = try makeJITReloader(epcFD, orcPath)
            jitReloader = reloader
            stage("JIT executor connected; compiling initial preview")
            let build = try await previewSession.compileObjectForJIT()

            // The render entry installs the SwiftUI hosting controller into the
            // agent's key window, which only exists once the shell completes the
            // hosting handshake and the agent's scene connects. Wait for the agent's
            // sceneReady signal so the render targets a real window deterministically.
            // The agent is a SwiftUI App; the render hands its controller to a store
            // the WindowGroup observes, so the render can run before the hosted
            // scene attaches (the store buffers it until SwiftUI's window is up).
            stage("rendering initial preview")
            try await reloader.render(build)
            stage("initial JIT render complete")
        } catch {
            throw await enrichedJITFailure(error)
        }

        do {
            let hidClient = try await simulatorManager.makeHIDClient(udid: deviceUDID)
            let streamer = try await simulatorManager.makeFramebufferStreamer(udid: deviceUDID)
            let frameSource = EventDrivenFrameSource(streamer: streamer)
            let videoStream = AVCCVideoStream()
            streamer.onFrameSurface = { surface in videoStream.feed(surface: surface) }
            stage("waiting for first framebuffer frame")
            let ready = await frameSource.waitForFirstFrame(timeout: .seconds(20))
            try Task.checkCancellation()
            stage(ready ? "display pipeline wired" : "display pipeline not wired (degraded)")
            let server = PreviewAppServer(
                sink: IndigoHIDInputSink(client: hidClient),
                frameSource: frameSource,
                videoStream: videoStream
            )
            appServerPort = try await server.start()
            appServer = server
            appFrameSource = frameSource
            appVideoStream = videoStream
            stage("app interface on 127.0.0.1:\(appServerPort ?? 0)")
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            Log.info("iOS preview: app interface unavailable: \(error)")
        }

        stage("connected; start complete")

        await channel.setOnDisconnect { [weak self] in
            await self?.handleUnexpectedAgentDeath()
        }

        return pid
    }

    /// Respawn the agent when it dies out of band (crash, user kill, sim
    /// eviction). The session owns the agent lifecycle, so recovery is
    /// unconditional — only `stop()` ends it. Suppressed during a planned
    /// `_relaunch()` (its own teardown EOFs the channel) and coalesced so
    /// concurrent death callbacks produce one respawn. See issue #253.
    private func handleUnexpectedAgentDeath() async {
        guard !stopping, !isRelaunching, !recovering else { return }
        recovering = true
        defer { recovering = false }

        await acquireRenderLock()
        defer { releaseRenderLock() }
        guard !stopping else { return }

        do {
            _ = try await _relaunch()
        } catch {
            print("iOS preview: agent respawn after unexpected death failed: \(error)")
        }
    }

    /// Close the socket connection and clean up resources. Idempotent —
    /// `IOSAgentChannel.close()` is safe to call when nothing was opened.
    public func stop() async {
        stopping = true

        appServer?.stop()
        appServer = nil
        appFrameSource?.stop()
        appFrameSource = nil
        appVideoStream?.stop()
        appVideoStream = nil
        appServerPort = nil

        // Take the render lock so stop wins the respawn race (#257). An iOS
        // eviction can have a `_relaunch` in flight (via `handleUnexpectedAgentDeath`)
        // holding the lock; without waiting it out, that respawn relaunches the agent
        // AFTER we tear down and orphans a host. Waiting drains the in-flight respawn,
        // then we terminate its result. Any respawn that starts later sees `stopping`
        // at its post-lock guard and bails, so it is safe to release after teardown.
        await acquireRenderLock()
        defer { releaseRenderLock() }

        // Kill the apps BEFORE tearing down the JIT session. The agent's live
        // SwiftUI view graph runs in JIT'd code, so freeing the session while the
        // agent is alive makes its next main-loop render fault on freed pages
        // (EXC_BAD_ACCESS). simctl terminate is a SIGKILL, clean with no crash
        // report, and a dead agent cannot render.
        await simulatorManager.terminateAppIfRunning(udid: deviceUDID, bundleID: Self.shellBundleID)
        await simulatorManager.terminateAppIfRunning(udid: deviceUDID, bundleID: Self.agentBundleID)

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

    /// If the host reported an in-app JIT failure over the JSON channel, return
    /// that as the error so the caller sees the host-side cause instead of a
    /// generic accept timeout or downstream link error; otherwise pass `fallback`
    /// through unchanged. See issue #217.
    private func enrichedJITFailure(_ fallback: Error) async -> Error {
        if let jitError = await channel.latestJITError {
            return IOSPreviewSessionError.jitExecutorFailed(
                stage: jitError.stage, code: jitError.code
            )
        }
        return fallback
    }

    /// Build a fresh `PreviewSession` for the current source, index, and traits.
    /// `start()` and `reload()` both recompile from a new session.
    private func makePreviewSession() -> PreviewSession {
        PreviewSession(
            sourceFile: sourceFile,
            previewIndex: previewIndex,
            compiler: compiler,
            platform: .iOS,
            buildContext: buildContext,
            traits: traits,
            setupModule: setupModule,
            setupType: setupType,
            setupCompilerFlags: setupCompilerFlags,
            setupSDKPath: setupSDKPath,
            setupDylibPath: setupDylibPath
        )
    }

    /// Latest resident memory (bytes) the agent app reported over the JSON channel.
    /// Zero before the first report or after a disconnect.
    public var agentRSS: UInt64 {
        get async { await channel.latestRSS }
    }

    /// Latest `applicationState` (`active` / `inactive` / `background`) the host
    /// app reported over the JSON channel. Nil before the first breadcrumb or
    /// after a disconnect. The flash detector: a shell-hosted agent must never
    /// report `active`.
    public var agentApplicationState: String? {
        get async { await channel.latestApplicationState }
    }

    // MARK: - Communication

    /// Recompile the preview to an object and re-link it into the live host over
    /// the EPC connection, re-running its render entry.
    public func reload() async throws {
        await acquireRenderLock()
        defer { releaseRenderLock() }

        guard await channel.isConnected else {
            throw IOSPreviewSessionError.notStarted
        }
        guard let jitReloader else {
            throw IOSPreviewSessionError.notStarted
        }

        let previewSession = makePreviewSession()
        session = previewSession

        // Link the freshly compiled object into the live host over EPC and re-run
        // its render entry. No dylib, no `reload` round-trip over the JSON channel.
        let build = try await previewSession.compileObjectForJIT()
        try await jitReloader.render(build)
    }

    /// Handle a watcher burst, mirroring macOS. An UNCHANGED primary file (no-op save, mtime
    /// touch, atomic-rename replay) is a no-op so the agent keeps its live `@State`. A literal-only
    /// edit rewrites the design-time values JSON and re-runs the same linked object over EPC (no
    /// recompile, no relink). A structural edit, or any burst that touched a SECONDARY watched
    /// file (a cross-file dependency), reuses the persistent session so its stable-module cache and
    /// literal baseline carry forward. `firedPaths` and `canonicalPrimary` are canonical, resolved
    /// when the watch was installed. An empty `firedPaths` treats the change as a primary edit.
    public func handleSourceChange(
        firedPaths: Set<String> = [], canonicalPrimary: String? = nil
    ) async throws {
        await acquireRenderLock()
        defer { releaseRenderLock() }

        guard await channel.isConnected, let jitReloader, let session else {
            throw IOSPreviewSessionError.notStarted
        }

        let newSource = try String(contentsOf: sourceFile, encoding: .utf8)
        switch await session.classifyWatchedChange(
            firedPaths: firedPaths,
            canonicalPrimary: canonicalPrimary ?? sourceFile.path,
            newPrimarySource: newSource
        ) {
        case .unchanged:
            return
        case let .literal(changes):
            if let build = try await session.applyLiteralValuesForJIT(changes) {
                try await jitReloader.render(build)
                await session.commitSourceBaseline(newSource)
                return
            }
        // No prior JIT build to patch: fall through to a structural reload.
        case .structural:
            break
        }

        let build = try await session.compileObjectForJIT()
        try await jitReloader.render(build)
    }

    /// Relaunch the whole agent app to reclaim leaked `__swift5_*`/ObjC metadata that the
    /// Swift runtime cannot unregister in-process. Tears down both sockets, terminates and
    /// relaunches the host, re-accepts the JSON and EPC channels, rebuilds the reloader, and
    /// re-renders the current source. Costs a full-screen flash and `@State` loss, so callers
    /// gate this on memory pressure and prefer a structural-edit boundary.
    @discardableResult
    public func relaunch() async throws -> Int {
        await acquireRenderLock()
        defer { releaseRenderLock() }
        return try await _relaunch()
    }

    /// Lock-free relaunch body. The internal memory-pressure path calls this directly,
    /// since it already holds the render lock; the public `relaunch()` wraps it in the lock.
    @discardableResult
    private func _relaunch() async throws -> Int {
        // Suppress the death watcher for the duration: this path terminates the
        // host itself, which EOFs the channel. Recovery reaches here with the
        // channel already disconnected, so there is no `isConnected` precondition.
        isRelaunching = true
        defer { isRelaunching = false }
        guard let orcPath = IOSAgentBuilder.jitOrcRuntimePath else {
            throw IOSPreviewSessionError.jitRuntimeMissing
        }
        guard let agentSockPath else {
            throw IOSPreviewSessionError.notStarted
        }

        // Kill the old agent BEFORE freeing its JIT session. On the memory-cap
        // path the agent is still alive and rendering JIT'd code, so freeing first
        // faults it on unmapped pages (EXC_BAD_ACCESS). A no-op on the death path,
        // where the agent is already gone.
        await simulatorManager.terminateAppIfRunning(udid: deviceUDID, bundleID: Self.agentBundleID)

        await channel.close()
        jitReloader = nil
        if jitListenFD >= 0 {
            Darwin.close(jitListenFD)
            jitListenFD = -1
        }

        let port = try await channel.bindAndListen()
        let jitPort = try bindJITListener()

        // Background launch (#352): the long-lived shell stays foreground and
        // the new agent never takes the screen, so the respawn is invisible
        // (no transient agent-active flash, no "< Agent" breadcrumb).
        let pid = try await simulatorManager.launchAppInBackground(
            udid: deviceUDID,
            bundleID: Self.agentBundleID,
            arguments: Self.agentLaunchArgs(port: port, jitPort: jitPort, agentSockPath: agentSockPath)
        )

        try await channel.awaitConnect(timeout: .seconds(10))

        // Flash-free respawn: the long-lived shell detects the old agent's death
        // (its agent-UDS EOFs), holds its cached frame + spinner, then reconnects
        // to the same stable sock path the new agent rebinds and re-hosts. No
        // shell relaunch, so the device display never blanks.
        do {
            let epcFD = try acceptJIT(timeoutSeconds: 10)
            let reloader = try makeJITReloader(epcFD, orcPath)
            jitReloader = reloader

            let previewSession = makePreviewSession()
            session = previewSession
            let build = try await previewSession.compileObjectForJIT()
            try await reloader.render(build)
        } catch {
            throw await enrichedJITFailure(error)
        }
        return pid
    }

    /// Switch to a different preview index and recompile. Traits are preserved. @State is lost.
    /// Rolls back the index if compilation fails.
    public func switchPreview(to newIndex: Int) async throws {
        let oldIndex = previewIndex
        previewIndex = newIndex
        do {
            try await reload()
        } catch {
            previewIndex = oldIndex
            throw error
        }
    }

    /// Update traits and recompile. Signals the agent app to reload. @State is lost.
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
        traits = newTraits
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
        let resultTree: [String: Any] = if filter != "all", let filtered = filterTree(tree, mode: filter) {
            filtered
        } else {
            tree
        }

        let data = try JSONSerialization.data(withJSONObject: resultTree)
        return String(data: data, encoding: .utf8) ?? "{}"
    }

    /// Capture a screenshot of the simulator.
    ///
    /// Capture through the live framebuffer streamer: it holds the SimulatorKit
    /// display pipeline wired open, so it succeeds at the requested quality even
    /// when the one-shot `SBCaptureFramebuffer` path cannot find an IOSurface
    /// (its cold port enumeration races display attach under load). Falls back
    /// to the one-shot capture when no streamer surface is wired yet.
    public func screenshot(jpegQuality: Double = 0.85) async throws -> Data {
        if let source = appFrameSource {
            // Default-quality snapshots read the streamer's last cached frame
            // directly. The event-driven stream already encoded it, so it is
            // non-blank, current within one display change, and — the point
            // here — non-blocking: it never contends on the serial capture queue
            // or the one-shot SBCaptureFramebuffer / simctl fallback. A
            // PNG/lossless request (quality >= 1.0) can't reuse the JPEG cache,
            // so it falls through to a fresh re-encode.
            if jpegQuality < 1.0, let cached = await source.nextFrame() {
                return cached
            }
            // Ride over brief surface gaps (e.g. the agent respawn the OS forces
            // periodically) before conceding to the load-racing one-shot path.
            for attempt in 0 ..< 3 {
                Log.info("iosSnap: cache miss — captureFresh attempt \(attempt + 1)/3")
                if let frame = await source.captureFresh(jpegQuality: jpegQuality) {
                    return frame
                }
                if attempt < 2 {
                    try? await Task.sleep(for: .milliseconds(100))
                }
            }
        }
        Log.info("iosSnap: falling back to one-shot capture")
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
            let interactableTraits: Set = ["button", "link", "adjustable", "searchField"]
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
    /// JSON parse or shape mismatch on a agent-app response. Distinct
    /// from `socketResponseTimeout` so callers and operators can tell
    /// "agent app didn't respond" from "agent app responded with garbage."
    case responseDecodeFailed(operation: String)
    /// The in-app ORC executor reported a failure over the JSON channel
    /// (`connect` = EPC socket never connected; `executor` = ORC server failed
    /// to start). Replaces the generic accept timeout / downstream link error
    /// with the host-side cause. See issue #217.
    case jitExecutorFailed(stage: String, code: Int?)
    /// The target simulator runs iOS older than 26, whose private scene-hosting
    /// API the shell needs is absent (#282). Live previews require iOS 26+.
    case unsupportedRuntime(String)

    public var description: String {
        switch self {
        case .notStarted: return "iOS preview session has not been started"
        case .socketCreateFailed: return "Failed to create TCP server socket"
        case .socketAcceptFailed: return "Failed to accept connection from agent app"
        case .socketAcceptTimeout: return "Timed out waiting for agent app to connect"
        case .jitRuntimeMissing: return "Bundled iossim orc runtime archive not found"
        case let .socketResponseTimeout(id): return "Timed out waiting for response (id: \(id))"
        case .connectionLost: return "Connection to agent app lost"
        case let .responseDecodeFailed(operation):
            return "Failed to decode agent app response (operation: \(operation))"
        case let .jitExecutorFailed(stage, code):
            let suffix = code.map { " (code \($0))" } ?? ""
            return "In-app JIT executor failed during \(stage)\(suffix)"
        case let .unsupportedRuntime(detail):
            return "iOS simulator unsupported for live preview: \(detail). Use an iOS 26+ simulator."
        }
    }

    public var errorDescription: String? {
        description
    }
}

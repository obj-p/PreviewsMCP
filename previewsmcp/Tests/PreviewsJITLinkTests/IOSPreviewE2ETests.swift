import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsJITLink
import Testing

/// End-to-end iOS preview tests: the daemon builds the real agent app, boots the
/// simulator, and drives the production `IOSPreviewSession` over EPC (flash-free
/// respawn, relaunch, JIT render, agent->shell redirect).
///
/// `.serialized` because every test shares one simulator, one agent-app bundle
/// ID, and one IOSAgentBuilder workDir, so they cannot run concurrently (parallel
/// runs clobber the agent-app source mid-build). See #244.
@Suite(.serialized)
struct IOSPreviewE2ETests {
    static let packageRoot: URL = {
        if let root = ProcessInfo.processInfo.environment["PREVIEWSMCP_REPO_ROOT"] {
            return URL(fileURLWithPath: root, isDirectory: true)
        }
        return URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }()

    /// Stage 0 (shell-owns-agent): the xcrun-free in-session spawn primitive.
    /// `SimulatorManager.spawnInSession` drives the default `SimDevice
    /// spawnWithPath:` (via SimulatorBridge) to run a program inside the device's
    /// boot session — the way `simctl spawn` does, but with no subprocess. A
    /// trivial executable that returns immediately must yield a real PID and fire
    /// the termination handler, proving in-session spawn works without xcrun.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(5)))
    func spawnInSessionRunsProgramAndReportsExit() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let exe = try IOSPreviewE2ESupport.compileExecutableForIOSSim(
            source: "int main(void) { return 0; }", name: "trivial_exit"
        )

        let manager = SimulatorManager()
        let exitStatus = ResultBox()
        let pid = try await manager.spawnInSession(
            udid: udid,
            program: exe.path,
            onExit: { status in exitStatus.set(status) }
        )
        #expect(pid > 0)

        // The termination handler fires once the trivial program returns.
        let deadline = Date().addingTimeInterval(30)
        while exitStatus.get() == nil, Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(exitStatus.get() != nil)
    }

    /// Stage 1 keystone (R1, networking half): an in-session-spawned process gets
    /// host-loopback networking. The spawned program connects to a 127.0.0.1
    /// listener on the host and writes a byte; receiving it proves `spawnInSession`
    /// (default `spawnWithPath:`) shares the boot session's network — refuting the
    /// prior claim that bare `spawnWithPath` is not in-session. This is what makes
    /// the daemon-side spawn a viable launch primitive (the plan's fallback).
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(5)))
    func inSessionSpawnGetsHostLoopbackNetworking() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let exe = try IOSPreviewE2ESupport.compileExecutableForIOSSim(
            source: """
            #include <sys/socket.h>
            #include <netinet/in.h>
            #include <arpa/inet.h>
            #include <unistd.h>
            #include <stdlib.h>
            int main(int argc, char **argv) {
                if (argc < 2) return 1;
                int fd = socket(AF_INET, SOCK_STREAM, 0);
                if (fd < 0) return 2;
                struct sockaddr_in addr;
                addr.sin_family = AF_INET;
                addr.sin_port = htons((unsigned short)atoi(argv[1]));
                addr.sin_addr.s_addr = inet_addr("127.0.0.1");
                if (connect(fd, (struct sockaddr *)&addr, sizeof(addr)) != 0) return 3;
                char b = 42;
                write(fd, &b, 1);
                close(fd);
                return 0;
            }
            """,
            name: "loopback_connect"
        )

        let listener = try IOSPreviewE2ESupport.openLoopbackListener()
        defer { close(listener.fd) }

        let manager = SimulatorManager()
        let pid = try await manager.spawnInSession(
            udid: udid,
            program: exe.path,
            arguments: [exe.path, String(listener.port)]
        )
        #expect(pid > 0)

        let conn = try IOSPreviewE2ESupport.acceptOne(listenFD: listener.fd, timeoutSeconds: 30)
        defer { close(conn) }
        var byte: UInt8 = 0
        let n = read(conn, &byte, 1)
        #expect(n == 1)
        #expect(byte == 42)
    }

    /// Phase 2 fold: the REAL production agent app (built by IOSAgentBuilder with
    /// the executor linked from PreviewsIOS resources) hosts the ORC executor
    /// and the daemon links + runs an object inside it over the EPC socket. JIT
    /// mode needs no preview dylib, so the app launches with `--jit-port` alone.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func hostsRemoteSessionInRealHostApp() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let object = try IOSPreviewE2ESupport.compileForIOSSim("answer.c")
        let appPath = try await IOSAgentBuilder().ensureAgentApp()
        try IOSPreviewE2ESupport.installApp(udid: udid, appPath: appPath.path)

        let listener = try IOSPreviewE2ESupport.openLoopbackListener()
        defer { close(listener.fd) }

        try IOSPreviewE2ESupport.launchApp(
            udid: udid, bundleID: IOSPreviewSession.agentBundleID,
            args: ["--jit-port", "\(listener.port)"]
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let conn = try IOSPreviewE2ESupport.acceptOne(listenFD: listener.fd, timeoutSeconds: 60)
        guard let orcPath = IOSAgentBuilder.jitOrcRuntimePath else {
            throw IOSPreviewE2ESupport.SpikeError.message("bundled iossim orc runtime missing")
        }
        let session = try JITSession(remoteFD: conn, orcRuntimePath: orcPath)
        try session.addObject(path: object.path)
        let result = try session.runMain(symbol: "answer")
        #expect(result == 42)
    }

    /// Chunk 4: the PRODUCTION IOSPreviewSession.start() stands up the EPC
    /// session over the second socket. It compiles + launches the real preview
    /// host (dylib + JSON channel as today) AND, given an injected JIT factory,
    /// binds a second listener, passes --jit-port, accepts the executor, and
    /// builds the remote session — proving the factory receives a live fd
    /// (it links answer.c and runs 42 inside the closure).
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func productionSessionEstablishesJITOverSecondSocket() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let object = try IOSPreviewE2ESupport.compileForIOSSim("answer.c")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-prod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let linked = ResultBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let s = try JITSession(remoteFD: fd, orcRuntimePath: orcPath)
                try s.addObject(path: object.path)
                linked.set(try s.runMain(symbol: "answer"))
                return CapturingReloader(session: s)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)
        #expect(linked.get() == 42)
        await session.stop()
    }

    /// End-to-end iOS JIT render: drives the REAL production `IOSPreviewSession.start()`
    /// with the production `IOSJITStructuralReloader` factory. start() compiles the preview
    /// to an object, injects it over EPC, and runs `renderPreviewToFile`, which hosts the
    /// SwiftUI view on the key window. The accessibility tree fetched over the JSON channel
    /// must then contain the rendered text — proving the preview renders over JIT, not dylib.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func endToEndRendersOverJIT() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)

        // Default quality → JPEG (0xFF 0xD8 SOI marker); quality 1.0 → PNG (0x89 'P').
        let jpeg = try await session.screenshot()
        #expect(jpeg.count > 1 && jpeg[0] == 0xFF && jpeg[1] == 0xD8)
        let png = try await session.screenshot(jpegQuality: 1.0)
        #expect(png.count > 1 && png[0] == 0x89 && png[1] == 0x50)

        let elements = try await session.fetchElements()
        #expect(elements.contains("Hello from iOS JIT!"))
        await session.stop()
    }

    /// Stage 0 (shell-owns-agent): the agent lifecycle breadcrumb. The agent app
    /// reports its `applicationState` over the JSON channel; `IOSPreviewSession`
    /// exposes the latest as `agentApplicationState`. After `start()` the daemon
    /// must observe a valid breadcrumb, proving the flash detector is wired end
    /// to end. The exact state is environment-dependent (a headless simctl launch
    /// reports `background`, not `active`); later shell-hosted stages assert the
    /// agent stays non-`active` across respawn, where the value is meaningful.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func agentReportsForegroundLifecycleState() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-lifecycle-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)

        var state: String?
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            state = await session.agentApplicationState
            if state != nil { break }
            try await Task.sleep(for: .milliseconds(200))
        }
        #expect(["active", "inactive", "background"].contains(state))
        await session.stop()
    }

    /// Keystone for #221 reclaim: `relaunch()` must terminate and relaunch the host, re-accept
    /// both the JSON and EPC channels, rebuild the reloader, and re-render the current source.
    /// After the relaunch the accessibility tree fetched over the (re-established) JSON channel
    /// must still contain the rendered text — proving the whole round-trip survives a host
    /// restart, which is how leaked `__swift5_*`/ObjC metadata is reclaimed.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func relaunchReRendersCurrentPreview() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)
        let before = try await session.fetchElements()
        #expect(before.contains("Hello from iOS JIT!"))

        // The host reports RSS once a second over the JSON channel; allow one tick.
        try await Task.sleep(for: .seconds(2))
        let reportedRSS = await session.agentRSS
        #expect(reportedRSS > 0)

        let newPid = try await session.relaunch()
        #expect(newPid > 0)
        #expect(newPid != pid)

        let after = try await session.fetchElements()
        #expect(after.contains("Hello from iOS JIT!"))

        // Stage 2 re-host evidence: save the post-relaunch DEVICE-DISPLAY frame
        // (the shell composite) for visual inspection. A JPEG-size assertion
        // cannot tell a re-hosted frame from a dead-black one (both ~70KB), so
        // the re-host check is the saved image, not an automated threshold.
        let afterShot = try await simulatorManager.screenshotData(udid: udid)
        let shotPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stage2-rehost.jpg")
        try afterShot.write(to: shotPath)
        print("[stage2] post-relaunch device display → \(shotPath.path) (\(afterShot.count) bytes)")
        await session.stop()
    }

    /// Flash-free gap verification: capture the device display rapidly WHILE a
    /// respawn happens. During the gap the shell should hold its cached frame +
    /// spinner (never black / springboard), then show the re-hosted content. No
    /// assertion (the signal is visual); saves frames to /tmp/flashfree-gap.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func flashFreeRespawnGap() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-gap-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.shellBundleID)
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        _ = try await session.start()
        let before = try await session.fetchElements()
        #expect(before.contains("Hello from iOS JIT!"))

        let outDir = URL(fileURLWithPath: "/tmp/flashfree-gap")
        try? FileManager.default.removeItem(at: outDir)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let baseline = try await simulatorManager.screenshotData(udid: udid)
        try baseline.write(to: outDir.appendingPathComponent("00-baseline.jpg"))

        // Kill ONLY the agent and do NOT relaunch it, so the shell sits in the
        // gap (retrying reconnect) — that is exactly when the cached-frame +
        // spinner overlay should be on screen. Capture it serially. With the fix
        // these frames show the held "Hello" + spinner; pre-fix they were black.
        await simulatorManager.terminateAppIfRunning(
            udid: udid, bundleID: IOSPreviewSession.agentBundleID
        )
        for i in 1 ... 8 {
            try await Task.sleep(for: .milliseconds(700))
            let shot = try await simulatorManager.screenshotData(udid: udid)
            try shot.write(to: outDir.appendingPathComponent(String(format: "%02d-gap.jpg", i)))
            print("[flashfree] gap frame \(i) (\(shot.count) bytes)")
            // Measured bands for this fixed preview: a black/dead-scene frame is
            // ~61KB, the held cached frame + dim + spinner is ~86KB, and the
            // springboard (shell crashed/backgrounded) is ~364KB. Require the
            // held band: not black (too small) and not springboard (too big).
            #expect(shot.count > 70000 && shot.count < 200_000)
        }
    }

    /// #257: `stop()` must win the race against an in-flight respawn. Killing the
    /// agent fires `onDisconnect` -> `handleUnexpectedAgentDeath` -> `_relaunch`,
    /// which holds the render lock across its `render`. If `stop()` does not take
    /// that lock it runs to completion while the respawn is mid-flight, then
    /// `_relaunch`'s relaunch leaves an orphaned host. The fix makes `stop()`
    /// acquire the render lock, so it blocks until the respawn drains, then kills
    /// its result. A `GatedReloader` parks the respawn's render (lock held open)
    /// so the probe is deterministic: with the fix `stop()` stays pending while the
    /// respawn is gated; without it `stop()` returns early. Green after the fix,
    /// red before it.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func stopWaitsOutInFlightRespawn() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-stop-race-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        // Gate the SECOND reloader the session builds: #1 is the initial `start()`
        // render, #2 is the respawn's render in `_relaunch`, which runs under the
        // render lock.
        let reloaderBox = GatedReloaderBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let inner = try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
                let reloader = GatedReloader(inner: inner, shouldGate: reloaderBox.count == 1)
                reloaderBox.add(reloader)
                return reloader
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.shellBundleID)
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        _ = try await session.start()
        #expect(try await session.fetchElements().contains("Hello from iOS JIT!"))

        // Kill the agent; the auto-respawn parks at its gated render, holding the lock.
        IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        let gateDeadline = Date().addingTimeInterval(30)
        while Date() < gateDeadline {
            if reloaderBox.gated()?.didEnterGate == true { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let gated = try #require(reloaderBox.gated())
        #expect(gated.didEnterGate, "respawn never reached its gated render")

        // Probe: with the lock, stop() must block behind the gated respawn.
        let stopDone = FlagBox()
        let stopTask = Task {
            await session.stop(); stopDone.set()
        }
        try await Task.sleep(for: .seconds(2))
        #expect(
            !stopDone.isSet,
            "stop() returned while a respawn was mid-flight — it did not take the render lock (#257)"
        )

        // Release the respawn; stop must now finish and leave no host behind.
        gated.openGate()
        await stopTask.value
        #expect(stopDone.isSet)
        try await Task.sleep(for: .seconds(2))
        #expect(
            !IOSPreviewE2ESupport.isAppRunning(udid: udid, bundleID: IOSPreviewSession.agentBundleID),
            "stop() must terminate the respawned agent it waited out"
        )
    }

    /// Concurrency: the file watcher fires a Task per change, so several reloads can race on
    /// the actor. handleSourceChange/reload must serialize so a second edit never interleaves
    /// with another's render or relaunch (which tears down and rebinds both sockets). A
    /// tracking reloader asserts no two renders overlap when many edits fire at once.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func concurrentEditsSerialize() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-serialize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let trackerBox = TrackerBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let tracker = ConcurrencyTrackingReloader(
                    inner: try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
                )
                trackerBox.set(tracker)
                return tracker
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        _ = try await session.start()

        // Fire several reloads at once; serialized renders must never overlap.
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0 ..< 5 {
                group.addTask { try await session.reload() }
            }
            try? await group.waitForAll()
        }

        let maxActive = trackerBox.get()?.maxActive ?? 0
        #expect(maxActive == 1)
        let elements = try await session.fetchElements()
        #expect(elements.contains("Hello from iOS JIT!"))
        await session.stop()
    }

    /// Literal-only edit over iOS JIT (#216): after the initial render, a change that
    /// touches only a `Text` string must re-seed the DesignTimeStore and re-run the SAME
    /// linked object — no recompile, no new generation — mirroring the macOS literal path.
    /// A `RecordingReloader` wraps the real reloader and captures each rendered object path.
    /// Red before the fix: `handleSourceChange` rebuilt the session and recompiled, so the
    /// second render carried a fresh object path.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func literalEditReSeedsSameObjectWithoutRecompile() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-literal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let recorderBox = RecorderBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let recorder = RecordingReloader(
                    inner: try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
                )
                recorderBox.set(recorder)
                return recorder
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)
        let before = try await session.fetchElements()
        #expect(before.contains("Hello from iOS JIT!"))

        let edited = Self.helloViewSource.replacingOccurrences(
            of: "Hello from iOS JIT!", with: "Hello from literal edit!"
        )
        try edited.write(to: sourceFile, atomically: true, encoding: .utf8)
        try await session.handleSourceChange()

        let after = try await session.fetchElements()
        #expect(after.contains("Hello from literal edit!"))

        let paths = recorderBox.get()?.objectPaths ?? []
        #expect(paths.count == 2)
        #expect(
            paths.first == paths.last,
            "literal edit must re-render the same object (no recompile)"
        )
        await session.stop()
    }

    /// End-to-end iOS JIT render WITH a setup plugin, over a real project build context
    /// (setup only applies when `splitContext` is non-nil, which needs a `buildContext`).
    /// The setup dylib (`ToDoPreviewSetup` built for the iOS sim) must be threaded into the
    /// JIT link so `previewSetUp` resolves and `wrap()` overlays its banner. Red before #215:
    /// `IOSPreviewSession` dropped `setupDylibPath`, so the setup symbols never linked.
    /// After the fix the banner's `dev@example.com` appears in the a11y tree.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func endToEndRendersSetupWrappedOverJIT() async throws {
        let udid = try IOSPreviewE2ESupport.bootSimulator()

        let hot = Self.packageRoot
            .appendingPathComponent("examples/spm/Sources/ToDo/Summary.swift")
        guard let spm = try await SPMBuildSystem.detect(for: hot) else {
            Issue.record("no SPM build system detected for \(hot.path)")
            return
        }
        let buildContext = try await spm.build(platform: .iOS)

        let configResult = try #require(
            ProjectConfigLoader.find(from: hot.deletingLastPathComponent())
        )
        let setupConfig = try #require(configResult.config.setup)
        let setup = try await SetupBuilder.build(
            config: setupConfig, configDirectory: configResult.directory, platform: .iOS
        )

        let compiler = try await Compiler(platform: .iOS)
        let agentBuilder = try await IOSAgentBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: hot,
            deviceUDID: udid,
            compiler: compiler,
            agentBuilder: agentBuilder,
            simulatorManager: simulatorManager,
            buildContext: buildContext,
            setupModule: setup.moduleName,
            setupType: setup.typeName,
            setupCompilerFlags: setup.compilerFlags,
            setupSDKPath: setup.sdkPath,
            setupDylibPath: setup.dylibPath,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            IOSPreviewE2ESupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.agentBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)

        let elements = try await session.fetchElements()
        #expect(elements.contains("dev@example.com"))
        await session.stop()
    }

    /// Repro for #282: the scene-hosting init the shell uses
    /// (`-[_UISceneHostingControllerAdvancedConfiguration initWithClientIdentity:]`,
    /// ShellMain.m) only exists on iOS 26. This spawns a probe inside a sub-26
    /// simulator that fires the SAME unguarded `performSelector:` and asserts it
    /// aborts with the issue's `unrecognized selector` signature. Self-skips where
    /// no pre-26 runtime is installed.
    ///
    /// Why a probe and not the production session: on this machine's pre-26 runtime
    /// (18.6) the real shell returns early in `clientIdentityForToken:` (FrontBoard
    /// hands back no client identity) before reaching the crash line, and the agent
    /// renders to its own window regardless — so an end-to-end render check cannot
    /// see the bug. The probe reproduces the crash deterministically on any sub-26
    /// runtime by calling the exact selector ShellMain calls.
    @Test(.enabled(if: preIOS26RuntimePresent), .timeLimit(.minutes(5)))
    func sceneHostingInitIsUnrecognizedSelectorOnPreIOS26() throws {
        let udid = try IOSPreviewE2ESupport.bootLegacySimulator()
        let probe = try IOSPreviewE2ESupport.compileObjCExecutableForIOSSim(
            source: Self.sceneHostingProbeSource, name: "scene_host_sel_probe"
        )
        let output = try IOSPreviewE2ESupport.spawnAndCapture(udid: udid, program: probe.path)
        #expect(
            output.contains(
                "-[_UISceneHostingControllerAdvancedConfiguration initWithClientIdentity:]"
            ),
            "probe output did not name the scene-hosting init:\n\(output)"
        )
        #expect(
            output.contains("unrecognized selector"),
            "scene-hosting init did not abort with an unrecognized-selector on a pre-26 runtime:\n\(output)"
        )
    }

    static var jitOrcRuntimePresent: Bool {
        IOSAgentBuilder.jitOrcRuntimePath != nil
    }

    static var preIOS26RuntimePresent: Bool {
        IOSPreviewE2ESupport.availableUDIDBelowIOS26() != nil
    }

    /// Mirrors ShellMain.m's `hostWithToken:` crash site: resolve the private
    /// scene-hosting config class and fire `initWithClientIdentity:` via
    /// `performSelector`. On iOS 26 the selector exists; on pre-26 it aborts with
    /// `unrecognized selector` (#282). The argument is a throwaway object — pre-26
    /// the selector is missing, so the call throws before the argument is used.
    static let sceneHostingProbeSource = """
    #import <Foundation/Foundation.h>
    #import <objc/runtime.h>
    #include <dlfcn.h>
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
    int main(void) {
        dlopen("/System/Library/PrivateFrameworks/UIKitCore.framework/UIKitCore", RTLD_NOW);
        Class AdvCfg = NSClassFromString(@"_UISceneHostingControllerAdvancedConfiguration");
        @try {
            id adv = [[AdvCfg alloc] performSelector:@selector(initWithClientIdentity:)
                                          withObject:[NSObject new]];
            printf("RESULT: no crash, adv=%s\\n", adv ? "non-nil" : "nil");
        } @catch (NSException *e) {
            printf("RESULT: %s\\n", e.reason.UTF8String);
        }
        return 0;
    }
    """

    static let helloViewSource = """
    import SwiftUI

    struct HelloView: View {
        var body: some View {
            Text("Hello from iOS JIT!")
                .font(.largeTitle)
                .padding()
        }
    }

    #Preview {
        HelloView()
    }
    """
}

/// Holds the remote JIT session for the lifetime of the preview session, mirroring
/// how the real reloader will retain it to drive renders.
private final class CapturingReloader: IOSStructuralReloader, @unchecked Sendable {
    let session: JITSession
    init(session: JITSession) {
        self.session = session
    }

    func render(_: JITRenderBuild) async throws {}
}

/// Wraps a real reloader and records the object path of every rendered build, so a test
/// can assert a literal re-render reused the same object (no recompile) while the inner
/// reloader still drives the real EPC render.
private final class RecordingReloader: IOSStructuralReloader, @unchecked Sendable {
    let inner: any IOSStructuralReloader
    private let lock = NSLock()
    private var paths: [String] = []
    init(inner: any IOSStructuralReloader) {
        self.inner = inner
    }

    func render(_ build: JITRenderBuild) async throws {
        lock.withLock { paths.append(build.objectPath.path) }
        try await inner.render(build)
    }

    var objectPaths: [String] {
        lock.withLock { paths }
    }
}

/// Wraps a real reloader and tracks how many `render` calls are in flight at once, so a test
/// can assert the session serializes its render entry points (max concurrency 1).
private final class ConcurrencyTrackingReloader: IOSStructuralReloader, @unchecked Sendable {
    let inner: any IOSStructuralReloader
    private let lock = NSLock()
    private var active = 0
    private(set) var maxActive = 0
    init(inner: any IOSStructuralReloader) {
        self.inner = inner
    }

    func render(_ build: JITRenderBuild) async throws {
        lock.withLock {
            active += 1
            maxActive = max(maxActive, active)
        }
        defer { lock.withLock { active -= 1 } }
        try await inner.render(build)
    }
}

/// Thread-safe box handing a `ConcurrencyTrackingReloader` back from the @Sendable factory.
private final class TrackerBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: ConcurrencyTrackingReloader?
    func set(_ v: ConcurrencyTrackingReloader) {
        lock.withLock { value = v }
    }

    func get() -> ConcurrencyTrackingReloader? {
        lock.withLock { value }
    }
}

/// Thread-safe box so the @Sendable factory closure can hand the recorder back to the test.
private final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RecordingReloader?
    func set(_ v: RecordingReloader) {
        lock.withLock { value = v }
    }

    func get() -> RecordingReloader? {
        lock.withLock { value }
    }
}

/// Wraps a real reloader and, when `shouldGate`, parks its `render` on a
/// continuation until the test opens the gate. `_relaunch` holds the render lock
/// across `render`, so gating the respawn's render keeps that lock held open,
/// letting a test deterministically probe whether `stop()` blocks behind it (#257).
private final class GatedReloader: IOSStructuralReloader, @unchecked Sendable {
    let inner: any IOSStructuralReloader
    let shouldGate: Bool
    private let lock = NSLock()
    private var entered = false
    private var release: CheckedContinuation<Void, Never>?
    init(inner: any IOSStructuralReloader, shouldGate: Bool) {
        self.inner = inner
        self.shouldGate = shouldGate
    }

    var didEnterGate: Bool {
        lock.withLock { entered }
    }

    func openGate() {
        lock.lock()
        let cont = release
        release = nil
        lock.unlock()
        cont?.resume()
    }

    func render(_ build: JITRenderBuild) async throws {
        if shouldGate {
            await withCheckedContinuation { cont in
                lock.withLock {
                    entered = true
                    release = cont
                }
            }
        }
        try await inner.render(build)
    }
}

/// Thread-safe box handing each `GatedReloader` back from the @Sendable factory.
/// `count` lets the factory decide which reloader to gate; `gated()` returns the
/// second one built (the respawn's).
private final class GatedReloaderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var reloaders: [GatedReloader] = []
    var count: Int {
        lock.withLock { reloaders.count }
    }

    func add(_ r: GatedReloader) {
        lock.withLock { reloaders.append(r) }
    }

    func gated() -> GatedReloader? {
        lock.withLock { reloaders.count >= 2 ? reloaders[1] : nil }
    }
}

/// Thread-safe one-shot flag, so a test can observe whether a spawned Task finished.
private final class FlagBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() {
        lock.withLock { value = true }
    }

    var isSet: Bool {
        lock.withLock { value }
    }
}

/// Thread-safe box so the @Sendable factory closure can report the linked result.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ v: Int32) {
        lock.lock(); value = v; lock.unlock()
    }

    func get() -> Int32? {
        lock.lock(); defer { lock.unlock() }; return value
    }
}

enum IOSPreviewE2ESupport {
    enum SpikeError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case let .message(m): m
            }
        }
    }

    static func compileForIOSSim(_ source: String) throws -> URL {
        let fixtures = if let root = ProcessInfo.processInfo.environment["PREVIEWSMCP_REPO_ROOT"] {
            URL(fileURLWithPath: root, isDirectory: true)
                .appendingPathComponent(
                    "previewsmcp/Tests/PreviewsJITLinkTests/Fixtures", isDirectory: true
                )
        } else {
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .appendingPathComponent("Fixtures", isDirectory: true)
        }
        let input = fixtures.appendingPathComponent(source)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewsJITLinkIOSSimFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let output = outDir.appendingPathComponent(
            (source as NSString).deletingPathExtension + ".o"
        )

        let sdk = try run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = "arm64-apple-ios16.0-simulator"
        let arguments: [String] = if input.pathExtension == "swift" {
            [
                "swiftc", "-c", "-parse-as-library", "-module-name", "Fixtures",
                "-target", target, "-sdk", sdk, input.path, "-o", output.path,
            ]
        } else {
            [
                "clang", "-target", target, "-isysroot", sdk,
                "-c", input.path, "-o", output.path,
            ]
        }
        let result = try run("/usr/bin/xcrun", arguments)
        guard result.status == 0 else {
            throw SpikeError.message("compiling \(source) for iossim failed:\n\(result.output)")
        }
        return output
    }

    /// Compile + link a trivial executable for the iphonesimulator so a test can
    /// spawn it inside a booted device. Returns the host path to the binary.
    static func compileExecutableForIOSSim(source: String, name: String) throws -> URL {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewsJITLinkIOSSimExe", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = outDir.appendingPathComponent("\(name).c")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let exe = outDir.appendingPathComponent(name)

        let sdk = try run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = "arm64-apple-ios16.0-simulator"
        let result = try run(
            "/usr/bin/xcrun",
            ["clang", "-target", target, "-isysroot", sdk, src.path, "-o", exe.path]
        )
        guard result.status == 0 else {
            throw SpikeError.message("compiling executable \(name) for iossim failed:\n\(result.output)")
        }
        return exe
    }

    /// Compile + link a trivial Objective-C executable for the iphonesimulator
    /// (links Foundation, ARC on). Returns the host path to the binary.
    static func compileObjCExecutableForIOSSim(source: String, name: String) throws -> URL {
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewsJITLinkIOSSimObjCExe", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let src = outDir.appendingPathComponent("\(name).m")
        try source.write(to: src, atomically: true, encoding: .utf8)
        let exe = outDir.appendingPathComponent(name)

        let sdk = try run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = "arm64-apple-ios16.0-simulator"
        let result = try run(
            "/usr/bin/xcrun",
            [
                "clang", "-target", target, "-isysroot", sdk, "-fobjc-arc",
                "-framework", "Foundation", src.path, "-o", exe.path,
            ]
        )
        guard result.status == 0 else {
            throw SpikeError.message("compiling ObjC executable \(name) for iossim failed:\n\(result.output)")
        }
        return exe
    }

    /// Run a program inside a booted simulator via `simctl spawn` and return its
    /// combined stdout/stderr.
    static func spawnAndCapture(udid: String, program: String) throws -> String {
        try run("/usr/bin/xcrun", ["simctl", "spawn", udid, program]).output
    }

    static func bootSimulator() throws -> String {
        // Reuse a booted iOS 26+ device if present; otherwise boot a supported
        // one. Live previews require iOS 26+ (#282), so a booted pre-26 device
        // (e.g. one left from the repro test) must not be picked here.
        if let booted = iPhoneUDID(state: "booted", whereMajor: { $0 >= 26 }) {
            return booted
        }
        guard let udid = iPhoneUDID(state: "available", whereMajor: { $0 >= 26 }) else {
            throw SpikeError.message("no available iOS 26+ iPhone simulator to boot")
        }
        _ = try run("/usr/bin/xcrun", ["simctl", "boot", udid])
        _ = try run("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
        return udid
    }

    /// First available iPhone on a runtime older than iOS 26, or nil. Used to gate
    /// and drive the #282 pre-iOS-26 scene-hosting repro.
    static func availableUDIDBelowIOS26() -> String? {
        iPhoneUDID(state: "available", whereMajor: { $0 < 26 })
    }

    /// First iPhone in the given simctl device `state` ("available" / "booted")
    /// whose iOS major version satisfies `predicate`. Runtime keys look like
    /// `com.apple.CoreSimulator.SimRuntime.iOS-18-3`; the major is the
    /// `iOS-<major>-<minor>` segment.
    private static func iPhoneUDID(state: String, whereMajor predicate: (Int) -> Bool) -> String? {
        guard
            let result = try? run(
                "/usr/bin/xcrun", ["simctl", "list", "devices", state, "--json"]
            ),
            let data = result.output.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = root["devices"] as? [String: Any]
        else {
            return nil
        }
        for (runtime, list) in devices {
            guard let major = iOSMajorVersion(fromRuntimeKey: runtime), predicate(major) else {
                continue
            }
            guard let entries = list as? [[String: Any]] else { continue }
            for entry in entries where (entry["name"] as? String ?? "").contains("iPhone") {
                if let udid = entry["udid"] as? String { return udid }
            }
        }
        return nil
    }

    private static func iOSMajorVersion(fromRuntimeKey key: String) -> Int? {
        guard let range = key.range(of: "SimRuntime.iOS-") else { return nil }
        let suffix = key[range.upperBound...]
        let major = suffix.prefix { $0 != "-" }
        return Int(major)
    }

    static func bootLegacySimulator() throws -> String {
        guard let udid = availableUDIDBelowIOS26() else {
            throw SpikeError.message("no available pre-iOS-26 iPhone simulator to boot")
        }
        _ = try run("/usr/bin/xcrun", ["simctl", "boot", udid])
        _ = try run("/usr/bin/xcrun", ["simctl", "bootstatus", udid, "-b"])
        return udid
    }

    static func installApp(udid: String, appPath: String) throws {
        let result = try run("/usr/bin/xcrun", ["simctl", "install", udid, appPath])
        guard result.status == 0 else {
            throw SpikeError.message("simctl install failed:\n\(result.output)")
        }
    }

    static func launchApp(udid: String, bundleID: String, args: [String]) throws {
        let result = try run(
            "/usr/bin/xcrun",
            ["simctl", "launch", "--terminate-running-process", udid, bundleID] + args
        )
        guard result.status == 0 else {
            throw SpikeError.message("simctl launch failed:\n\(result.output)")
        }
    }

    static func terminateApp(udid: String, bundleID: String) {
        _ = try? run("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID])
    }

    /// Whether an app is currently running on the sim. `launchctl list` inside the
    /// sim labels running apps `UIKitApplication:<bundleID>[...]`, so a substring
    /// match on the bundle id is sufficient.
    static func isAppRunning(udid: String, bundleID: String) -> Bool {
        guard
            let result = try? run(
                "/usr/bin/xcrun", ["simctl", "spawn", udid, "launchctl", "list"]
            )
        else {
            return false
        }
        return result.output.contains(bundleID)
    }

    static func openLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpikeError.message("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = (0x7F00_0001 as in_addr_t).bigEndian
        addr.sin_port = 0
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(fd); throw SpikeError.message("bind failed") }
        guard listen(fd, 1) == 0 else { close(fd); throw SpikeError.message("listen failed") }

        var name = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &name) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(fd, $0, &len)
            }
        }
        return (fd, UInt16(bigEndian: name.sin_port))
    }

    static func acceptOne(listenFD: Int32, timeoutSeconds: Int32) throws -> Int32 {
        var pfd = pollfd(fd: listenFD, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, timeoutSeconds * 1000)
        guard ready > 0 else {
            throw SpikeError.message("timed out waiting for executor to connect")
        }
        let conn = accept(listenFD, nil, nil)
        guard conn >= 0 else { throw SpikeError.message("accept failed") }
        return conn
    }

    private static func run(_ executable: String, _ arguments: [String]) throws
        -> (status: Int32, output: String)
    {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}

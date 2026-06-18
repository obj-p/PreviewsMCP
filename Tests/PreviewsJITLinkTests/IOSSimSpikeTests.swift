import Foundation
import PreviewsCore
import PreviewsIOS
import PreviewsJITLink
import Testing

/// Phase 0 spike: prove the macOS daemon can drive an ORC executor running
/// inside an iOS simulator process and link + run an object there. The executor
/// (`.build-iossim/iossim-executor`, built by scripts/build-iossim-executor.sh)
/// connects back over TCP loopback, which the simulator shares with the host,
/// and the daemon builds the remote session over that fd. Gated on the iossim
/// artifacts so the macOS bar is unaffected when they are absent.
struct IOSSimSpikeTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    static var executor: URL {
        packageRoot.appendingPathComponent(".build-iossim/iossim-executor")
    }

    static var orcRuntime: URL {
        packageRoot.appendingPathComponent(
            "third_party/llvm-build-rt/lib/darwin/liborc_rt_iossim.a")
    }

    static var artifactsPresent: Bool {
        FileManager.default.isExecutableFile(atPath: executor.path)
            && FileManager.default.fileExists(atPath: orcRuntime.path)
    }

    @Test(.enabled(if: artifactsPresent), .timeLimit(.minutes(5)))
    func linksCObjectRemotelyIntoSimulator() throws {
        try SimSpikeSupport.withRemoteSession(fixture: "answer.c") { session in
            let result = try session.runMain(symbol: "answer")
            #expect(result == 42)
        }
    }

    @Test(.enabled(if: artifactsPresent), .timeLimit(.minutes(5)))
    func linksSwiftObjectRemotelyIntoSimulator() throws {
        try SimSpikeSupport.withRemoteSession(fixture: "swift_answer.swift") { session in
            let result = try session.runMain(symbol: "swift_answer")
            #expect(result == 42)
        }
    }

    @Test(.enabled(if: artifactsPresent), .timeLimit(.minutes(5)))
    func runsOnMainThreadInSimulator() throws {
        try SimSpikeSupport.withRemoteSession(fixture: "main_thread_probe.swift") { session in
            let offMain = try session.runMain(symbol: "main_thread_probe")
            #expect(offMain == 0)
            let onMain = try session.runOnMain(symbol: "main_thread_probe")
            #expect(onMain == 1)
        }
    }

    @Test(.enabled(if: artifactsPresent), .timeLimit(.minutes(5)))
    func buildsUIHostingControllerInSimulator() throws {
        try SimSpikeSupport.withRemoteSession(fixture: "ios_hosting_probe.swift") { session in
            let result = try session.runOnMain(symbol: "ios_hosting_probe_value")
            #expect(result == 1)
        }
    }

    @Test(.enabled(if: artifactsPresent), .timeLimit(.minutes(5)))
    func rendersSwiftUIContentInSimulator() throws {
        try SimSpikeSupport.withRemoteSession(fixture: "ios_render_probe.swift") { session in
            let packed = try session.runOnMain(symbol: "ios_render_probe_value")
            #expect(packed >= 0)
            let r = (packed >> 16) & 0xFF
            let g = (packed >> 8) & 0xFF
            let b = packed & 0xFF
            #expect(r > 200 && g < 60 && b < 60)
        }
    }

    /// Phase 2 fold: the REAL production host app (built by IOSHostBuilder with
    /// the executor linked from PreviewsIOS resources) hosts the ORC executor
    /// and the daemon links + runs an object inside it over the EPC socket. JIT
    /// mode needs no preview dylib, so the app launches with `--jit-port` alone.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func hostsRemoteSessionInRealHostApp() async throws {
        let udid = try SimSpikeSupport.bootSimulator()
        let object = try SimSpikeSupport.compileForIOSSim("answer.c")
        let appPath = try await IOSHostBuilder().ensureHostApp()
        try SimSpikeSupport.installApp(udid: udid, appPath: appPath.path)

        let listener = try SimSpikeSupport.openLoopbackListener()
        defer { close(listener.fd) }

        try SimSpikeSupport.launchApp(
            udid: udid, bundleID: IOSPreviewSession.hostBundleID,
            args: ["--jit-port", "\(listener.port)"])
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        let conn = try SimSpikeSupport.acceptOne(listenFD: listener.fd, timeoutSeconds: 60)
        guard let orcPath = IOSHostBuilder.jitOrcRuntimePath else {
            throw SimSpikeSupport.SpikeError.message("bundled iossim orc runtime missing")
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
        let udid = try SimSpikeSupport.bootSimulator()
        let object = try SimSpikeSupport.compileForIOSSim("answer.c")

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-prod-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let linked = ResultBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let s = try JITSession(remoteFD: fd, orcRuntimePath: orcPath)
                try s.addObject(path: object.path)
                linked.set(try s.runMain(symbol: "answer"))
                return CapturingReloader(session: s)
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
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
        let udid = try SimSpikeSupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
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

    /// Keystone for #221 reclaim: `relaunch()` must terminate and relaunch the host, re-accept
    /// both the JSON and EPC channels, rebuild the reloader, and re-render the current source.
    /// After the relaunch the accessibility tree fetched over the (re-established) JSON channel
    /// must still contain the rendered text — proving the whole round-trip survives a host
    /// restart, which is how leaked `__swift5_*`/ObjC metadata is reclaimed.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func relaunchReRendersCurrentPreview() async throws {
        let udid = try SimSpikeSupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-relaunch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)
        let before = try await session.fetchElements()
        #expect(before.contains("Hello from iOS JIT!"))

        // The host reports RSS once a second over the JSON channel; allow one tick.
        try await Task.sleep(for: .seconds(2))
        let reportedRSS = await session.hostRSS
        #expect(reportedRSS > 0)

        let newPid = try await session.relaunch()
        #expect(newPid > 0)
        #expect(newPid != pid)

        let after = try await session.fetchElements()
        #expect(after.contains("Hello from iOS JIT!"))
        await session.stop()
    }

    /// Chunk 3 gating: a structural edit past the memory threshold relaunches the host
    /// instead of relinking in place. With the threshold forced to 0, the first structural
    /// edit seeds the RSS baseline (no relaunch) and the second crosses it, so `relaunchCount`
    /// becomes 1 and the latest edit must still render — proving the gate fires at the edit
    /// boundary and the fresh process shows the current source.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func structuralEditPastThresholdRelaunches() async throws {
        func structuralSource(rows: Int) -> String {
            let extra = (0..<rows).map { "                    Text(\"row \($0)\")" }.joined(separator: "\n")
            return """
                import SwiftUI

                struct HelloView: View {
                    var body: some View {
                        VStack {
                            Text("Hello from iOS JIT!")
                \(extra)
                        }
                    }
                }

                #Preview {
                    HelloView()
                }
                """
        }

        let udid = try SimSpikeSupport.bootSimulator()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try structuralSource(rows: 0).write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            memoryRelaunchThresholdBytes: 0,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        _ = try await session.start()
        try await Task.sleep(for: .seconds(2))  // let the first RSS report arrive

        // First structural edit seeds the baseline — no relaunch yet.
        try structuralSource(rows: 1).write(to: sourceFile, atomically: true, encoding: .utf8)
        try await session.handleSourceChange()
        let countAfterFirst = await session.relaunchCount
        #expect(countAfterFirst == 0)

        // Second structural edit crosses baseline + 0 — relaunch fires here.
        try structuralSource(rows: 2).write(to: sourceFile, atomically: true, encoding: .utf8)
        try await session.handleSourceChange()
        let countAfterSecond = await session.relaunchCount
        #expect(countAfterSecond == 1)

        let elements = try await session.fetchElements()
        #expect(elements.contains("row 1"))
        await session.stop()
    }

    /// Gate covers the reload path too: `reload()` (used by switchPreview/reconfigure/
    /// setTraits) mints a fresh object, so it links a new generation and grows the leak
    /// like a structural edit. With the threshold forced to 0, the first reload seeds the
    /// baseline and the second crosses it, so a relaunch must fire (relaunchCount == 1).
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func reloadPastThresholdRelaunches() async throws {
        let udid = try SimSpikeSupport.bootSimulator()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-reloadgate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            memoryRelaunchThresholdBytes: 0,
            makeJITReloader: { fd, orcPath in
                try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath)
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        _ = try await session.start()
        try await Task.sleep(for: .seconds(2))  // let the first RSS report arrive

        try await session.reload()
        let countAfterFirst = await session.relaunchCount
        #expect(countAfterFirst == 0)

        try await session.reload()
        let countAfterSecond = await session.relaunchCount
        #expect(countAfterSecond == 1)

        let elements = try await session.fetchElements()
        #expect(elements.contains("Hello from iOS JIT!"))
        await session.stop()
    }

    /// Concurrency: the file watcher fires a Task per change, so several reloads can race on
    /// the actor. handleSourceChange/reload must serialize so a second edit never interleaves
    /// with another's render or relaunch (which tears down and rebinds both sockets). A
    /// tracking reloader asserts no two renders overlap when many edits fire at once.
    @Test(.enabled(if: jitOrcRuntimePresent), .timeLimit(.minutes(10)))
    func concurrentEditsSerialize() async throws {
        let udid = try SimSpikeSupport.bootSimulator()
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-serialize-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let trackerBox = TrackerBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let tracker = ConcurrencyTrackingReloader(
                    inner: try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath))
                trackerBox.set(tracker)
                return tracker
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        _ = try await session.start()

        // Fire several reloads at once; serialized renders must never overlap.
        await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
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
        let udid = try SimSpikeSupport.bootSimulator()

        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-ios-jit-literal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }
        let sourceFile = tempDir.appendingPathComponent("HelloView.swift")
        try Self.helloViewSource.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let recorderBox = RecorderBox()
        let session = IOSPreviewSession(
            sourceFile: sourceFile,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
            simulatorManager: simulatorManager,
            makeJITReloader: { fd, orcPath in
                let recorder = RecordingReloader(
                    inner: try IOSJITStructuralReloader(remoteFD: fd, orcRuntimePath: orcPath))
                recorderBox.set(recorder)
                return recorder
            }
        )
        defer {
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)
        let before = try await session.fetchElements()
        #expect(before.contains("Hello from iOS JIT!"))

        let edited = Self.helloViewSource.replacingOccurrences(
            of: "Hello from iOS JIT!", with: "Hello from literal edit!")
        try edited.write(to: sourceFile, atomically: true, encoding: .utf8)
        try await session.handleSourceChange()

        let after = try await session.fetchElements()
        #expect(after.contains("Hello from literal edit!"))

        let paths = recorderBox.get()?.objectPaths ?? []
        #expect(paths.count == 2)
        #expect(
            paths.first == paths.last,
            "literal edit must re-render the same object (no recompile)")
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
        let udid = try SimSpikeSupport.bootSimulator()

        let hot = Self.packageRoot
            .appendingPathComponent("examples/spm/Sources/ToDo/Summary.swift")
        guard let spm = try await SPMBuildSystem.detect(for: hot) else {
            Issue.record("no SPM build system detected for \(hot.path)")
            return
        }
        let buildContext = try await spm.build(platform: .iOS)

        let configResult = try #require(
            ProjectConfigLoader.find(from: hot.deletingLastPathComponent()))
        let setupConfig = try #require(configResult.config.setup)
        let setup = try await SetupBuilder.build(
            config: setupConfig, configDirectory: configResult.directory, platform: .iOS)

        let compiler = try await Compiler(platform: .iOS)
        let hostBuilder = try await IOSHostBuilder()
        let simulatorManager = SimulatorManager()

        let session = IOSPreviewSession(
            sourceFile: hot,
            deviceUDID: udid,
            compiler: compiler,
            hostBuilder: hostBuilder,
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
            SimSpikeSupport.terminateApp(udid: udid, bundleID: IOSPreviewSession.hostBundleID)
        }

        let pid = try await session.start()
        #expect(pid > 0)

        let elements = try await session.fetchElements()
        #expect(elements.contains("dev@example.com"))
        await session.stop()
    }

    static var jitOrcRuntimePresent: Bool {
        IOSHostBuilder.jitOrcRuntimePath != nil
    }

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
    init(session: JITSession) { self.session = session }
    func render(_ build: JITRenderBuild) async throws {}
}

/// Wraps a real reloader and records the object path of every rendered build, so a test
/// can assert a literal re-render reused the same object (no recompile) while the inner
/// reloader still drives the real EPC render.
private final class RecordingReloader: IOSStructuralReloader, @unchecked Sendable {
    let inner: any IOSStructuralReloader
    private let lock = NSLock()
    private var paths: [String] = []
    init(inner: any IOSStructuralReloader) { self.inner = inner }
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
    init(inner: any IOSStructuralReloader) { self.inner = inner }
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
    func set(_ v: ConcurrencyTrackingReloader) { lock.withLock { value = v } }
    func get() -> ConcurrencyTrackingReloader? { lock.withLock { value } }
}

/// Thread-safe box so the @Sendable factory closure can hand the recorder back to the test.
private final class RecorderBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: RecordingReloader?
    func set(_ v: RecordingReloader) { lock.withLock { value = v } }
    func get() -> RecordingReloader? { lock.withLock { value } }
}

/// Thread-safe box so the @Sendable factory closure can report the linked result.
private final class ResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Int32?
    func set(_ v: Int32) { lock.lock(); value = v; lock.unlock() }
    func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return value }
}

enum SimSpikeSupport {
    enum SpikeError: Error, CustomStringConvertible {
        case message(String)
        var description: String {
            switch self {
            case let .message(m): return m
            }
        }
    }

    static func withRemoteSession(
        fixture: String, _ body: (JITSession) throws -> Void
    ) throws {
        let udid = try bootSimulator()
        let object = try compileForIOSSim(fixture)

        let listener = try openLoopbackListener()
        defer { close(listener.fd) }

        let proc = try spawnExecutor(
            udid: udid, executor: IOSSimSpikeTests.executor, port: listener.port)
        defer { proc.terminate() }

        let conn = try acceptOne(listenFD: listener.fd, timeoutSeconds: 60)
        let session = try JITSession(
            remoteFD: conn, orcRuntimePath: IOSSimSpikeTests.orcRuntime.path)
        try session.addObject(path: object.path)
        try body(session)
    }

    static func compileForIOSSim(_ source: String) throws -> URL {
        let input = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures", isDirectory: true)
            .appendingPathComponent(source)
        let outDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewsJITLinkIOSSimFixtures", isDirectory: true)
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
        let output = outDir.appendingPathComponent(
            (source as NSString).deletingPathExtension + ".o")

        let sdk = try run("/usr/bin/xcrun", ["--sdk", "iphonesimulator", "--show-sdk-path"])
            .output.trimmingCharacters(in: .whitespacesAndNewlines)
        let target = "arm64-apple-ios16.0-simulator"
        let arguments: [String]
        if input.pathExtension == "swift" {
            arguments = [
                "swiftc", "-c", "-parse-as-library", "-module-name", "Fixtures",
                "-target", target, "-sdk", sdk, input.path, "-o", output.path,
            ]
        } else {
            arguments = [
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

    static func bootSimulator() throws -> String {
        if let udid = firstUDID(
            in: try run(
                "/usr/bin/xcrun", ["simctl", "list", "devices", "booted"]
            ).output)
        {
            return udid
        }
        guard
            let udid = firstUDID(
                in: try run(
                    "/usr/bin/xcrun", ["simctl", "list", "devices", "available"]
                ).output,
                onLinesMatching: "iPhone")
        else {
            throw SpikeError.message("no available iPhone simulator to boot")
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
            ["simctl", "launch", "--terminate-running-process", udid, bundleID] + args)
        guard result.status == 0 else {
            throw SpikeError.message("simctl launch failed:\n\(result.output)")
        }
    }

    static func terminateApp(udid: String, bundleID: String) {
        _ = try? run("/usr/bin/xcrun", ["simctl", "terminate", udid, bundleID])
    }

    static func spawnExecutor(udid: String, executor: URL, port: UInt16) throws -> Process {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
        p.arguments = ["simctl", "spawn", udid, executor.path, "port=\(port)"]
        try p.run()
        return p
    }

    static func openLoopbackListener() throws -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw SpikeError.message("socket failed") }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = (0x7f00_0001 as in_addr_t).bigEndian
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

    private static func firstUDID(in text: String, onLinesMatching needle: String? = nil)
        -> String?
    {
        for line in text.split(separator: "\n") {
            if let needle, !line.contains(needle) { continue }
            guard let open = line.firstIndex(of: "("), line[open...].count >= 38 else { continue }
            let start = line.index(after: open)
            let candidate = line[start...].prefix(36)
            if candidate.count == 36, candidate.allSatisfy({ $0.isHexDigit || $0 == "-" }) {
                return String(candidate)
            }
        }
        return nil
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

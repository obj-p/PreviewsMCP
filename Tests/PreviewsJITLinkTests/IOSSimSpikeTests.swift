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

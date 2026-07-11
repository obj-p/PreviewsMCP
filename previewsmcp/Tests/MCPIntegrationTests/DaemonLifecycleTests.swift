import Foundation
import MCP
import Network
import PreviewsCLI
import PreviewsTestSupport
import Testing

/// Integration tests for `previewsmcp serve --daemon` / `status` / `kill-daemon`.
///
/// These tests spawn the real `previewsmcp` binary and speak MCP over the Unix
/// domain socket. They assume no other daemon is running — each test cleans up
/// after itself, and the suite is serialized so they don't race.
@Suite(.serialized)
struct DaemonLifecycleTests {
    // MARK: - Paths

    static let binaryPath: String = MCPTestServer.binaryPath

    /// This test's per-run socket dir (#283): the $TEST_TMPDIR-derived isolated
    /// dir under Bazel, or an explicit `PREVIEWSMCP_SOCKET_DIR` override.
    static var baseSocketDir: String {
        DaemonTestLock.socketDir ?? DaemonTestLock.effectiveSocketDir
    }

    /// The `serve.sock` path inside `dir`.
    static func socketPath(inDir dir: String) -> String {
        (dir as NSString).appendingPathComponent("serve.sock")
    }

    /// Socket path for the current test's daemon (the shared per-run dir).
    static var socketPath: String {
        socketPath(inDir: baseSocketDir)
    }

    /// Environment for a spawned daemon/CLI: the current env with
    /// `PREVIEWSMCP_SOCKET_DIR` forced to `socketDir` (defaulting to this
    /// test's per-run socket dir, #283) so the daemon's production
    /// `DaemonPaths` resolves there.
    private static func childEnv(
        socketDir: String? = nil
    ) -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PREVIEWSMCP_SOCKET_DIR"] = socketDir ?? baseSocketDir
        return env
    }

    // MARK: - Test helpers

    /// Kill any daemon running in the current test's socket directory.
    private static func cleanSlate() async throws {
        _ = try? await runCLI(["kill-daemon", "--timeout", "2"])
    }

    /// Start a daemon in the background. Returns the Process; caller must
    /// terminate it (or kill-daemon) in cleanup. `env`/`socketPath` default to
    /// the shared per-run socket dir; pass both to run on an isolated dir.
    private static func startDaemon(
        env: [String: String]? = nil,
        socketPath: String? = nil
    ) async throws -> Process {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = ["serve", "--daemon"]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        proc.environment = env ?? Self.childEnv()
        try proc.run()

        let currentSocketPath = socketPath ?? Self.socketPath
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: currentSocketPath) { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        #expect(
            FileManager.default.fileExists(atPath: currentSocketPath),
            "daemon did not create socket within 5s"
        )
        try await Task.sleep(nanoseconds: 100_000_000)
        return proc
    }

    /// Run a CLI subcommand. `env` defaults to the shared per-run socket dir;
    /// pass a custom env to target an isolated dir.
    @discardableResult
    private static func runCLI(
        _ args: [String], env: [String: String]? = nil
    ) async throws -> (stdout: String, exit: Int32) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: binaryPath)
        proc.arguments = args
        proc.environment = env ?? Self.childEnv()
        let out = Pipe()
        proc.standardOutput = out
        proc.standardError = FileHandle.nullDevice
        try proc.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        proc.waitUntilExit()
        let stdout = String(data: data, encoding: .utf8) ?? ""
        return (stdout, proc.terminationStatus)
    }

    // MARK: - Tests

    @Test("status reports 'not running' when no daemon is active")
    func statusNoDaemon() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let (out, exit) = try await Self.runCLI(["status"])
            #expect(out.contains("not running"))
            #expect(exit == 1, "status should exit non-zero when daemon is down")
        }
    }

    @Test("daemon creates socket and pid file, status reports running")
    func daemonStartAndStatus() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let proc = try await Self.startDaemon()
            defer { proc.terminate() }

            let (out, exit) = try await Self.runCLI(["status"])
            #expect(out.contains("daemon running"))
            #expect(out.contains(Self.socketPath))
            #expect(exit == 0)
        }
    }

    @Test("MCP client can connect to daemon and list tools")
    func mcpClientListsTools() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let proc = try await Self.startDaemon()
            defer { proc.terminate() }

            let connection = NWConnection(
                to: NWEndpoint.unix(path: Self.socketPath),
                using: .tcp
            )
            let transport = daemonChannelTransport(connection: connection)
            let client = Client(name: "daemon-lifecycle-test", version: "1.0")
            _ = try await client.connect(transport: transport)
            defer {
                Task { await client.disconnect() }
            }

            let response = try await client.listTools()
            #expect(!response.tools.isEmpty, "daemon should expose MCP tools")
            let names = Set(response.tools.map { $0.name })
            #expect(names.contains("preview_list"))
            #expect(names.contains("preview_snapshot"))
        }
    }

    @Test("kill-daemon terminates the daemon and removes socket")
    func killDaemonCleansUp() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let proc = try await Self.startDaemon()
            defer {
                // In case kill-daemon failed, force termination so the test doesn't leak.
                if proc.isRunning { proc.terminate() }
            }

            let (out, exit) = try await Self.runCLI(["kill-daemon", "--timeout", "5"])
            #expect(exit == 0, "kill-daemon should exit 0: \(out)")
            #expect(out.contains("stopped"))

            // Verify files were cleaned up.
            #expect(!FileManager.default.fileExists(atPath: Self.socketPath))

            // Verify status reports not running.
            let (statusOut, statusExit) = try await Self.runCLI(["status"])
            #expect(statusOut.contains("not running"))
            #expect(statusExit == 1)
        }
    }

    @Test("starting a second daemon refuses and exits non-zero")
    func secondDaemonRefuses() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let proc = try await Self.startDaemon()
            defer { proc.terminate() }

            let secondProc = Process()
            secondProc.executableURL = URL(fileURLWithPath: Self.binaryPath)
            secondProc.arguments = ["serve", "--daemon"]
            secondProc.environment = Self.childEnv()
            let errPipe = Pipe()
            secondProc.standardError = errPipe
            secondProc.standardOutput = FileHandle.nullDevice
            try secondProc.run()
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            secondProc.waitUntilExit()
            let stderr = String(data: errData, encoding: .utf8) ?? ""
            #expect(secondProc.terminationStatus != 0, "second daemon should fail")
            #expect(stderr.contains("already running"))
        }
    }

    /// Catches a race: if the PID file is missing (daemon was started, PID
    /// write hadn't happened yet, or someone deleted it), a startup check
    /// based on PID alone lets a second daemon proceed. That second daemon
    /// would then unlink the still-live daemon's socket file, corrupting the
    /// running system.
    ///
    /// The correct check is a socket `connect()` probe: if anything is
    /// listening on the socket, refuse to start — regardless of PID file
    /// state.
    ///
    /// Without the fix this test would hang (second daemon rebinds and runs
    /// indefinitely), so we use a bounded wait and fail fast.
    @Test("second daemon refuses even when PID file is missing but socket is alive")
    func secondDaemonRefusesWithMissingPIDFile() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let proc = try await Self.startDaemon()
            defer { proc.terminate() }

            // Simulate the race: PID file gone, but daemon still running.
            let pidPath = (Self.socketPath as NSString)
                .deletingLastPathComponent
                .appending("/serve.pid")
            try? FileManager.default.removeItem(atPath: pidPath)

            let secondProc = Process()
            secondProc.executableURL = URL(fileURLWithPath: Self.binaryPath)
            secondProc.arguments = ["serve", "--daemon"]
            secondProc.environment = Self.childEnv()
            let errPipe = Pipe()
            secondProc.standardError = errPipe
            secondProc.standardOutput = FileHandle.nullDevice
            try secondProc.run()

            // Bounded wait: the second daemon should refuse and exit within ~2s.
            // If it doesn't, the race bug has corrupted state — fail the test
            // (rather than hanging) by terminating it.
            let deadline = Date().addingTimeInterval(2)
            while secondProc.isRunning, Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            let refusedInTime = !secondProc.isRunning
            if secondProc.isRunning {
                secondProc.terminate()
                secondProc.waitUntilExit()
            }
            let errData = errPipe.fileHandleForReading.readDataToEndOfFile()
            let stderr = String(data: errData, encoding: .utf8) ?? ""

            #expect(refusedInTime, "second daemon should exit quickly, not keep running")
            #expect(secondProc.terminationStatus != 0, "second daemon should refuse")
            #expect(
                stderr.contains("already running"),
                "should detect live daemon via socket probe: \(stderr)"
            )

            #expect(
                FileManager.default.fileExists(atPath: Self.socketPath),
                "daemon A's socket file should not have been removed by failed daemon B"
            )

            let connection = NWConnection(
                to: NWEndpoint.unix(path: Self.socketPath),
                using: .tcp
            )
            let transport = daemonChannelTransport(connection: connection)
            let client = Client(name: "race-test", version: "1.0")
            _ = try await client.connect(transport: transport)
            await client.disconnect()
        }
    }

    @Test("kill-daemon on stale PID file cleans up without error")
    func killDaemonStalePID() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            // Write a PID file pointing to a definitely-dead process
            // in the current test's isolated socket directory.
            let dir = URL(fileURLWithPath: Self.socketPath)
                .deletingLastPathComponent()
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try "99999\n".write(
                to: dir.appendingPathComponent("serve.pid"),
                atomically: true, encoding: .utf8
            )

            let (out, exit) = try await Self.runCLI(["kill-daemon"])
            #expect(exit == 0)
            #expect(out.contains("stale"))
        }
    }

    /// End-to-end characterization for #274: a socket directory reached through
    /// a symlink round-trips. The reported case was `PREVIEWSMCP_SOCKET_DIR`
    /// under `/tmp` (itself a symlink to `/private/tmp`), where `status`
    /// reported "daemon starting or shutting down" even though the daemon had
    /// bound and logged ready.
    ///
    /// Scope note: production's `DaemonPaths` derives the socket path from a
    /// single `Path.normalize(PREVIEWSMCP_SOCKET_DIR)` used by BOTH the daemon
    /// bind and the client probe, and the kernel resolves symlinks at
    /// bind/connect time — so the two sides agree by construction and this test
    /// passes on current main (the reported failure did not reproduce here). It
    /// therefore locks the symlinked-dir round trip as a smoke test; it does
    /// not, and structurally cannot, fail on a one-sided path change while the
    /// two sides still resolve to the same inode.
    ///
    /// Self-contained (its own symlinked dir + env) so it needs neither the
    /// shared per-run socket dir nor the cross-suite lock.
    @Test("client finds the daemon when the socket dir is reached through a symlink (#274)")
    func clientConnectsThroughSymlinkedSocketDir() async throws {
        let fm = FileManager.default
        let base = Self.baseSocketDir
        let realDir = base + "-274real"
        let linkDir = base + "-274link"
        try? fm.removeItem(atPath: linkDir)
        try? fm.removeItem(atPath: realDir)
        try fm.createDirectory(atPath: realDir, withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: linkDir, withDestinationPath: realDir)
        defer {
            try? fm.removeItem(atPath: linkDir)
            try? fm.removeItem(atPath: realDir)
        }

        // Confirm the test's premise via the filesystem, not the string we
        // just wrote: linkDir must resolve through a symlink to realDir.
        let resolvedLink = URL(fileURLWithPath: linkDir).resolvingSymlinksInPath().path
        #expect(resolvedLink == realDir)
        #expect(resolvedLink != linkDir)

        let env = Self.childEnv(socketDir: linkDir)
        let socketPath = Self.socketPath(inDir: linkDir)

        let daemon = try await Self.startDaemon(env: env, socketPath: socketPath)
        defer {
            // kill-daemon (via the pid file) is the robust cleanup for this
            // one-off dir; a bare terminate() would miss a detached daemon.
            // defer can't await, so kill synchronously via a Process.
            let kill = Process()
            kill.executableURL = URL(fileURLWithPath: Self.binaryPath)
            kill.arguments = ["kill-daemon", "--timeout", "5"]
            kill.environment = env
            kill.standardOutput = FileHandle.nullDevice
            kill.standardError = FileHandle.nullDevice
            try? kill.run()
            kill.waitUntilExit()
            if daemon.isRunning { daemon.terminate() }
        }

        // The exact #274 symptom surface: the CLI readiness / pid path must
        // report the daemon running, not "starting or shutting down".
        let (status, exit) = try await Self.runCLI(["status"], env: env)
        #expect(status.contains("daemon running"), "status did not see the daemon: \(status)")
        #expect(exit == 0)

        // And a real MCP client completes a round trip over the symlinked path.
        let connection = NWConnection(to: NWEndpoint.unix(path: socketPath), using: .tcp)
        let client = Client(name: "socket-symlink-test", version: "1.0")
        _ = try await client.connect(transport: daemonChannelTransport(connection: connection))
        defer { Task { await client.disconnect() } }

        let response = try await client.listTools()
        #expect(!response.tools.isEmpty, "daemon should expose tools over the symlinked socket")
    }
}

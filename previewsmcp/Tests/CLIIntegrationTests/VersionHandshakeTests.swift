import Foundation
import Testing

/// Integration tests for the client-side version handshake — issue #142.
///
/// The persistent daemon survives CLI upgrades, so a new CLI binary can
/// find itself talking to a daemon booted from the old one. Simulated
/// here by spawning the daemon with `_PREVIEWSMCP_TEST_DAEMON_VERSION`
/// set (the server advertises the override in its MCP `serverInfo`
/// while the client continues to use its compile-time version). The
/// handshake should detect the mismatch, kill the stale daemon, and
/// respawn a matching one — transparently, from the user's point of
/// view.
@Suite(.serialized)
struct VersionHandshakeTests {

    private static let staleVersion = "0.0.0-stale-test"

    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    /// Manually spawn a daemon with the given server-version override
    /// and wait for it to start listening. Returns the daemon's PID so
    /// tests can confirm it died during restart. The override is set
    /// only on this subprocess — subsequent `CLIRunner.run` children
    /// inherit the test runner's env (which doesn't carry it), so
    /// their client-side version comparison uses the real value.
    private static func spawnStaleDaemon(version: String) async throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
        proc.arguments = ["serve", "--daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        var env = ProcessInfo.processInfo.environment
        env["_PREVIEWSMCP_TEST_DAEMON_VERSION"] = version
        proc.environment = env

        try proc.run()
        // `serve --daemon` runs the AppKit event loop and never exits
        // on its own — don't waitUntilExit. The test will kill it via
        // `kill-daemon` during cleanup. Poll until the daemon's pid
        // file is written and the socket is accepting connections.
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let pid = try? readPidFile(), isAlive(pid) {
                // Also wait for the socket — the pid file is written
                // after `DaemonListener.start` returns, but the daemon
                // is still finalizing. Probe by connecting.
                if try await socketReady(timeout: 5) {
                    return pid
                }
            }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw VersionHandshakeTestError.staleDaemonStartupTimeout
    }

    private static func readPidFile() throws -> Int32 {
        let contents = try String(contentsOf: daemonPidFile, encoding: .utf8)
        guard let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw VersionHandshakeTestError.pidFileUnparseable(contents) }
        return pid
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    private static func socketReady(timeout: TimeInterval) async throws -> Bool {
        // Use `previewsmcp status` as a no-op liveness probe that
        // doesn't engage the handshake-restart path. Its exit code is
        // 0 iff the daemon is accepting connections.
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let result = try await CLIRunner.run("status", timeout: .seconds(5))
            if result.exitCode == 0 { return true }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        return false
    }

    private static var daemonPidFile: URL {
        daemonDirectory.appendingPathComponent("serve.pid")
    }

    private static var daemonDirectory: URL {
        if let override = ProcessInfo.processInfo.environment["PREVIEWSMCP_SOCKET_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".previewsmcp", isDirectory: true)
    }

    // MARK: - Tests

    /// New CLI, stale daemon: the next CLI command detects the
    /// mismatch, prints the restart banner, kills the stale daemon,
    /// respawns a fresh one, and succeeds.
    @Test(
        "CLI restarts a stale daemon transparently and the command succeeds",
        .timeLimit(.minutes(2))
    )
    func happyPathRestart() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let stalePid = try await Self.spawnStaleDaemon(version: Self.staleVersion)

            let result = try await CLIRunner.run("simulators")
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            #expect(
                result.stderr.contains("restarting")
                    && result.stderr.contains(Self.staleVersion),
                "banner should call out the stale version: \(result.stderr)"
            )
            // Authoritative: pid file now points at a different daemon
            // than the one we spawned stale. Not `isAlive(stalePid)`
            // — macOS can reuse pids, so a reused-pid-for-new-daemon
            // scenario would false-positive that check even though
            // the restart worked correctly.
            let newPid = try Self.readPidFile()
            #expect(
                newPid != stalePid,
                "pid file should reference the respawned daemon, not \(stalePid)"
            )
            #expect(
                Self.isAlive(newPid),
                "respawned daemon (pid \(newPid)) should be running"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Matching versions: the CLI must not log the banner and must not
    /// restart the daemon. Guards against a regression where we
    /// unconditionally restart.
    @Test(
        "CLI does not restart the daemon when versions match",
        .timeLimit(.minutes(2))
    )
    func noRestartWhenVersionsMatch() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            // First invocation spawns a fresh daemon at the real
            // compile-time version — no mismatch possible.
            let first = try await CLIRunner.run("simulators")
            #expect(first.exitCode == 0, "stderr: \(first.stderr)")
            let firstPid = try Self.readPidFile()

            // Second invocation connects to the live daemon and
            // performs the handshake. Must be a silent no-op.
            let second = try await CLIRunner.run("simulators")
            #expect(second.exitCode == 0, "stderr: \(second.stderr)")
            #expect(
                !second.stderr.contains("restarting"),
                "unexpected restart banner: \(second.stderr)"
            )
            let secondPid = try Self.readPidFile()
            #expect(
                secondPid == firstPid,
                "daemon should be unchanged: \(firstPid) vs \(secondPid)"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }

    /// Two concurrent CLI invocations against a stale daemon should
    /// serialize via the restart lock: exactly one performs the kill+
    /// respawn, the other observes the freshly-restarted daemon on
    /// re-probe and skips the banner. Both commands succeed and there
    /// is exactly one running daemon at the end.
    @Test(
        "concurrent CLIs against a stale daemon restart it exactly once",
        .timeLimit(.minutes(2))
    )
    func concurrentClientsRestartOnce() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()

            // Truncate serve.log so our breadcrumb count is scoped
            // to this test's window (DaemonTestLock only appends a
            // marker; it does not clear the log on every test).
            try? Data().write(to: CLIRunner.daemonLogFile)

            let stalePid = try await Self.spawnStaleDaemon(version: Self.staleVersion)

            async let resultA = CLIRunner.run("simulators")
            async let resultB = CLIRunner.run("simulators")
            let (a, b) = try await (resultA, resultB)

            #expect(a.exitCode == 0, "A stderr: \(a.stderr)")
            #expect(b.exitCode == 0, "B stderr: \(b.stderr)")

            // Authoritative assertion: exactly one daemon respawn
            // happened. The breadcrumb is emitted exactly once by
            // ServeCommand.runDaemon per version-mismatch respawn,
            // regardless of how the two CLIs race for the lock. The
            // stderr banner count is weaker — both CLIs could race
            // into the re-probe path under heavy scheduling skew.
            let logContents =
                (try? String(contentsOf: CLIRunner.daemonLogFile, encoding: .utf8)) ?? ""
            let breadcrumbCount =
                logContents.components(
                    separatedBy: "started after version-mismatch restart"
                ).count - 1
            #expect(
                breadcrumbCount == 1,
                "exactly one respawn should have fired; got \(breadcrumbCount). serve.log: \(logContents)"
            )

            let finalPid = try Self.readPidFile()
            #expect(
                finalPid != stalePid,
                "pid file should reference the respawned daemon, not \(stalePid)"
            )
            #expect(
                Self.isAlive(finalPid),
                "exactly one daemon (pid \(finalPid)) should be running"
            )

            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
        }
    }
}

private enum VersionHandshakeTestError: Error, CustomStringConvertible {
    case staleDaemonStartupTimeout
    case pidFileUnparseable(String)

    var description: String {
        switch self {
        case .staleDaemonStartupTimeout:
            return "manual stale-daemon startup did not complete within 10s"
        case .pidFileUnparseable(let contents):
            return "pid file contents unparseable: \(contents)"
        }
    }
}

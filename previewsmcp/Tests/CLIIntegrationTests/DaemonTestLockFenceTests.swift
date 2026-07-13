import Foundation
import Testing

/// The writer-fence in `DaemonTestLock.run` teardown must guarantee no daemon
/// is left writing the shared `serve.log` when the lock frees — otherwise its
/// stderr byte-races the next locked window's reader (the LogsCommandTests
/// flake). These drive the fence deterministically, without the CI-load race
/// that surfaced it: a daemon left alive in-block, and a writer that refuses
/// SIGTERM, must both be dead by the time `run` returns.
@Suite(.serialized)
struct DaemonTestLockFenceTests {
    @Test(
        "a daemon left alive in-block is confirmed dead after the lock releases",
        .timeLimit(.minutes(2))
    )
    func fenceReapsDaemonLeftAliveInBlock() async throws {
        // Return the pid out of the @Sendable block rather than capturing a var.
        let pid: Int32 = try await DaemonTestLock.run {
            // Start from a known state, then spawn a daemon and deliberately
            // do NOT stop it — mirroring RunCommand `--detach`, whose daemon
            // outlives its block today.
            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
            let pid = try await Self.spawnDaemon()
            #expect(Self.isAlive(pid), "precondition: daemon should be live in-block")
            return pid
        }

        let dead = !Self.isAlive(pid)
        if !dead {
            // Don't orphan the daemon into the rest of the run on the fail path.
            _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "5"])
        }
        #expect(dead, "teardown fence must confirm daemon pid \(pid) dead before releasing the lock")
    }

    @Test(
        "the fence escalates to SIGKILL when a writer refuses SIGTERM",
        .timeLimit(.minutes(1))
    )
    func fenceEscalatesToSIGKILL() async throws {
        // Hermetic: drive the escalation primitive DIRECTLY against a throwaway
        // stub with a short grace — no daemon lock held, no serve.pid touched —
        // so this test can't perturb the concurrent suite. The stub signals
        // READY only after its SIGTERM trap is installed, so the grace wait is
        // guaranteed to elapse and force the SIGKILL escalation.
        let pid = try await Self.spawnSIGTERMIgnoringProcess()
        let escalated = await DaemonTestLock.confirmProcessDead(pid, graceSeconds: 0.2)

        let dead = !Self.isAlive(pid)
        if !dead { kill(pid, SIGKILL) }
        // escalated == true rules out a false green: a graceful SIGTERM reap
        // would return false, so this only passes via the actual SIGKILL path.
        #expect(escalated, "a SIGTERM-proof writer must force the SIGKILL escalation, not a graceful reap")
        #expect(dead, "the fence must reap the writer (pid \(pid))")
    }

    // MARK: - Helpers

    private static var pidFile: URL {
        URL(fileURLWithPath: DaemonTestLock.effectiveSocketDir, isDirectory: true)
            .appendingPathComponent("serve.pid")
    }

    private static func isAlive(_ pid: Int32) -> Bool {
        kill(pid, 0) == 0
    }

    /// Spawn a shell that traps SIGTERM to a no-op, then — only once the trap
    /// is installed — touches a ready file and loops. Waiting on the ready
    /// file before returning closes the run()-returns-before-trap race, so the
    /// teardown fence is guaranteed to meet a genuinely SIGTERM-proof writer
    /// and must escalate to SIGKILL to reap it.
    private static func spawnSIGTERMIgnoringProcess() async throws -> Int32 {
        let ready = FileManager.default.temporaryDirectory
            .appendingPathComponent("fence-stub-ready-\(UUID().uuidString)")
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/sh")
        proc.arguments = ["-c", "trap '' TERM; : > '\(ready.path)'; while :; do sleep 1; done"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        try proc.run()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: ready.path) {
                try? FileManager.default.removeItem(at: ready)
                return proc.processIdentifier
            }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        proc.terminate()
        throw FenceTestError.stubReadyTimeout
    }

    /// Spawn a real daemon (`serve --daemon`) on this run's socket dir and
    /// wait until its pid file is written and it is alive. No render, so it's
    /// cheap. Mirrors VersionHandshakeTests.spawnStaleDaemon minus the
    /// version override.
    private static func spawnDaemon() async throws -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: CLIRunner.binaryPath)
        proc.arguments = ["serve", "--daemon"]
        proc.standardInput = FileHandle.nullDevice
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        var env = ProcessInfo.processInfo.environment
        env["PREVIEWSMCP_SOCKET_DIR"] = DaemonTestLock.effectiveSocketDir
        proc.environment = env
        try proc.run()

        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            if let pid = readPIDFile(), isAlive(pid) { return pid }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw FenceTestError.daemonStartupTimeout
    }

    private static func readPIDFile() -> Int32? {
        guard
            let contents = try? String(contentsOf: pidFile, encoding: .utf8),
            let pid = Int32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        return pid
    }
}

private enum FenceTestError: Error {
    case daemonStartupTimeout
    case stubReadyTimeout
}

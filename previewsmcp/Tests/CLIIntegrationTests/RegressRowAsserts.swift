import Foundation
import Testing

/// Shared row-contract helpers for the regress guard suites
/// (`RegressGuardTests` in the required-gate target,
/// `RegressToolGuardTests` in the `manual` tool target). Both targets
/// compile this file (`HARNESS_SRCS`), so the snapshot/PNG/lock
/// composition cannot drift between the two suites.
enum RegressRowAsserts {
    static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    static func fixture(_ relativePath: String) -> String {
        CLIRunner.regressRoot.appendingPathComponent(relativePath).path
    }

    /// Run a one-shot snapshot of `relativePath` with no detection overrides
    /// and assert it renders a valid, non-blank PNG. Returns the CLI result
    /// so callers can pin stderr notice/progress tokens. `thenWhileAlive`
    /// runs inside the same lock block, before the writer-fence kills the
    /// daemon, for assertions that need the daemon's state (logs, status).
    @discardableResult
    static func assertRenders(
        _ relativePath: String,
        extraArguments: [String] = [],
        thenWhileAlive: @Sendable () async throws -> Void = {}
    ) async throws -> CLIResult {
        try await DaemonTestLock.run {
            try await cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [fixture(relativePath), "-o", outputPath] + extraArguments
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
            try CLIRunner.assertNonBlankPNG(at: outputPath)
            try await thenWhileAlive()
            return result
        }
    }

    /// Run a one-shot snapshot of `relativePath` and assert it fails with
    /// every expected diagnostic token in the combined output. `thenWhileAlive`
    /// runs inside the same lock block, before the writer-fence kills the
    /// daemon.
    static func assertFails(
        _ relativePath: String,
        extraArguments: [String] = [],
        containing expected: [String],
        thenWhileAlive: @Sendable () async throws -> Void = {}
    ) async throws {
        try await DaemonTestLock.run {
            try await cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [fixture(relativePath), "-o", outputPath] + extraArguments
            )
            #expect(result.exitCode != 0, "expected a classified failure, got success")
            let combined = result.stdout + result.stderr
            for token in expected {
                #expect(
                    combined.contains(token),
                    "diagnostic should contain '\(token)'; got: \(combined)"
                )
            }
            try await thenWhileAlive()
        }
    }
}

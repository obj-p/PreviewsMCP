import Foundation
@testable import PreviewsCLI
import Testing

/// Unit tests for `DaemonClient.waitForSocket(timeout:child:)`. The contract:
/// when the spawned daemon child exits before the socket comes up, throw
/// `daemonStartupFailed(exitCode:)` promptly instead of polling to the full
/// timeout (issue #99). A stand-in child (`/bin/sh -c 'exit N'`) substitutes
/// for the real daemon so the test is deterministic and fast.
@Suite(.serialized)
struct WaitForSocketTests {
    /// Point `DaemonPaths` at an empty directory so `DaemonProbe.connect()`
    /// returns nil (no `serve.sock`), run `body`, then restore the prior override.
    private func withEmptySocketDir(_ body: () async throws -> Void) async throws {
        let key = "PREVIEWSMCP_SOCKET_DIR"
        let previous = ProcessInfo.processInfo.environment[key]
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("waitforsocket-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        setenv(key, dir.path, 1)
        defer {
            if let previous { setenv(key, previous, 1) } else { unsetenv(key) }
            try? FileManager.default.removeItem(at: dir)
        }
        try await body()
    }

    @Test("throws daemonStartupFailed with the child's exit code")
    func surfacesExitCode() async throws {
        try await withEmptySocketDir {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/bin/sh")
            proc.arguments = ["-c", "exit 3"]
            try proc.run()
            proc.waitUntilExit()

            await #expect(throws: DaemonClientError.daemonStartupFailed(exitCode: 3)) {
                try await DaemonClient.waitForSocket(timeout: 5, child: proc)
            }
        }
    }

    @Test("times out when no child is supplied and the socket never appears")
    func timesOutWithoutChild() async throws {
        try await withEmptySocketDir {
            await #expect(throws: DaemonClientError.startupTimedOut) {
                try await DaemonClient.waitForSocket(timeout: 0.3, child: nil)
            }
        }
    }
}

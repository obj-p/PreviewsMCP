import Testing
import Foundation
@testable import PreviewsCore

@Suite("AsyncProcess")
struct AsyncProcessTests {

    @Test("captures stdout")
    func captureStdout() async throws {
        let output = try await runAsync("/bin/echo", arguments: ["hello"])
        #expect(output.stdout == "hello")
        #expect(output.exitCode == 0)
    }

    @Test("captures stderr and non-zero exit code")
    func captureStderrAndExit() async throws {
        let output = try await runAsync("/bin/sh", arguments: ["-c", "echo err >&2; exit 42"])
        #expect(output.exitCode == 42)
        #expect(output.stderr.contains("err"))
    }

    @Test("discardStderr returns empty stderr")
    func discardStderr() async throws {
        let output = try await runAsync(
            "/bin/sh", arguments: ["-c", "echo ok; echo err >&2"],
            discardStderr: true
        )
        #expect(output.stdout == "ok")
        #expect(output.stderr.isEmpty)
        #expect(output.exitCode == 0)
    }

    @Test("respects workingDirectory")
    func workingDirectory() async throws {
        let output = try await runAsync("/bin/pwd", workingDirectory: URL(fileURLWithPath: "/tmp"))
        // /tmp may resolve to /private/tmp on macOS
        #expect(output.stdout == "/tmp" || output.stdout == "/private/tmp")
    }
}

import Foundation
import Testing

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

    @Test("timeout SIGTERMs the subprocess and throws AsyncProcessTimeout")
    func timeoutFiresOnHungChild() async throws {
        // /bin/sleep 30 would exceed a 500ms timeout by a lot. With the
        // timer set, the call must return within ~1s (timer + terminate
        // propagation). This is the regression guard for the simctl
        // screenshot hang — see CI run 72501335737 on PR #140.
        let start = ContinuousClock.now
        await #expect(throws: AsyncProcessTimeout.self) {
            _ = try await runAsync(
                "/bin/sleep", arguments: ["30"],
                timeout: .milliseconds(500)
            )
        }
        let elapsed = ContinuousClock.now - start
        let elapsedSeconds =
            Double(elapsed.components.seconds)
            + Double(elapsed.components.attoseconds) / 1e18
        #expect(
            elapsedSeconds >= 0.5 && elapsedSeconds < 3,
            "expected timeout in 0.5-3s (got \(elapsedSeconds)s)"
        )
    }

    @Test("timeout does not fire on a fast subprocess")
    func timeoutDoesNotFirePrematurely() async throws {
        // Generous 5s timeout against a subprocess that exits immediately;
        // must return with the normal exit code, not an AsyncProcessTimeout.
        let output = try await runAsync(
            "/bin/echo", arguments: ["hello"],
            timeout: .seconds(5)
        )
        #expect(output.stdout == "hello")
        #expect(output.exitCode == 0)
    }

    @Test("timeout captures the child's pre-kill stdout and stderr")
    func timeoutCapturesOutput() async throws {
        // Child emits a marker to both streams (important: fflush so the
        // bytes actually leave the child's stdio buffer before we kill it),
        // then blocks forever. Timeout must surface both strings on the
        // error — that's the observability contract the simctl bootstatus
        // caller depends on to tell "stuck on SpringBoard" apart from
        // "stuck on data migration."
        do {
            _ = try await runAsync(
                "/bin/sh",
                arguments: [
                    "-c",
                    "printf 'booting SpringBoard\\n' ; printf 'stage=kickoff\\n' >&2 ; sleep 30",
                ],
                timeout: .milliseconds(500)
            )
            Issue.record("expected AsyncProcessTimeout, got success")
        } catch let t as AsyncProcessTimeout {
            #expect(
                t.capturedStdout.contains("booting SpringBoard"),
                "expected pre-kill stdout, got: \(t.capturedStdout.debugDescription)")
            #expect(
                t.capturedStderr.contains("stage=kickoff"),
                "expected pre-kill stderr, got: \(t.capturedStderr.debugDescription)")
        }
    }
}

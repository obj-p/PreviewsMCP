import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `stop`'s daemon-relay logic (`StopCommand.stopOne(client:)` and
/// `.stopAll(client:)`), tested against a `FakeDaemonClient` — no daemon
/// spawn, no simulator. Real subprocess coverage (actually stopping a live
/// session, which depends on the daemon's own behavior) stays in
/// `CLIIntegrationTests/StopCommandTests.swift`.
@Suite("stop daemon-relay logic")
struct StopCommandLogicTests {
    @Test("stop errors when no session is running")
    func stopOneNoSession() async throws {
        let command = try StopCommand.parse([])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        await expectValidationError(contains: "No session found to stop") {
            try await command.stopOne(client: client)
        }

        #expect(client.calls.map(\.name) == ["session_list"])
    }

    @Test("stop surfaces a daemon-reported tool error")
    func stopOneDaemonError() async throws {
        let command = try StopCommand.parse([])
        let client = FakeDaemonClient(responses: [
            "session_list": .foundSession,
            "preview_stop": .daemonError("session already stopped"),
        ])

        await expectDaemonToolError(contains: "session already stopped") {
            try await command.stopOne(client: client)
        }
    }

    @Test("stop --all is a no-op when no sessions are running")
    func stopAllNoSessions() async throws {
        let command = try StopCommand.parse(["--all"])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        try await command.stopAll(client: client)

        #expect(client.calls.map(\.name) == ["session_list"])
    }

    @Test("stop --all stops every active session")
    func stopAllStopsEverySession() async throws {
        let command = try StopCommand.parse(["--all"])
        let client = FakeDaemonClient(
            responses: ["session_list": .twoSessions],
            sequences: [
                "preview_stop": [
                    CallTool.Result(content: []),
                    CallTool.Result(content: []),
                ],
            ]
        )

        try await command.stopAll(client: client)

        #expect(client.calls.map(\.name) == ["session_list", "preview_stop", "preview_stop"])
        let stoppedSessionIDs = client.calls.dropFirst().map { $0.arguments?["sessionID"] }
        #expect(stoppedSessionIDs == [.string("session-a"), .string("session-b")])
    }

    @Test("stop --all keeps sweeping after one session fails, then throws the first failure")
    func stopAllContinuesSweepAfterFailure() async throws {
        let command = try StopCommand.parse(["--all"])
        let client = FakeDaemonClient(
            responses: ["session_list": .twoSessions],
            sequences: [
                // Both sessions fail, with distinct messages, so the
                // assertion below can only pass if the FIRST failure is
                // what's thrown — a last-failure-wins regression would
                // surface "session-b boom" instead and fail this test.
                "preview_stop": [
                    .daemonError("session-a wedged"),
                    .daemonError("session-b boom"),
                ],
            ]
        )

        await expectDaemonToolError(contains: "session-a wedged") {
            try await command.stopAll(client: client)
        }

        // Both sessions were attempted even though the first one failed.
        #expect(client.calls.map(\.name) == ["session_list", "preview_stop", "preview_stop"])
    }
}

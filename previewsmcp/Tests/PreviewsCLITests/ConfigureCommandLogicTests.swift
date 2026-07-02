import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `configure`'s daemon-relay logic (`ConfigureCommand.execute(on:)`),
/// tested against a `FakeDaemonClient` — no daemon spawn, no simulator.
/// Real subprocess coverage (rendered-output diff, trait clearing,
/// explicit --session targeting, which depend on the daemon's own
/// behavior) stays in `CLIIntegrationTests/ConfigureCommandTests.swift`.
@Suite("configure daemon-relay logic")
struct ConfigureCommandLogicTests {
    @Test("configure errors when no session is running")
    func configureNoSession() async throws {
        let command = try ConfigureCommand.parse(["--color-scheme", "dark"])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        await expectValidationError(contains: "No session found to configure") {
            try await command.execute(on: client)
        }

        #expect(client.calls.map(\.name) == ["session_list"])
    }

    @Test("configure surfaces a daemon-reported tool error")
    func configureDaemonError() async throws {
        let command = try ConfigureCommand.parse(["--color-scheme", "dark"])
        let client = FakeDaemonClient(responses: [
            "session_list": .foundSession,
            "preview_configure": .daemonError("invalid trait combination"),
        ])

        await expectDaemonToolError(contains: "invalid trait combination") {
            try await command.execute(on: client)
        }
    }
}

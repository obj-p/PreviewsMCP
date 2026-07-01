import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `touch`'s daemon-relay logic (`TouchCommand.execute(on:)`), tested
/// against a `FakeDaemonClient` — no daemon spawn, no simulator. Real
/// subprocess coverage (macOS-session error path, which depends on the
/// daemon's own policy) stays in `CLIIntegrationTests/TouchCommandTests.swift`.
@Suite("touch daemon-relay logic")
struct TouchCommandLogicTests {
    @Test("touch errors when no session is running")
    func touchNoSession() async throws {
        let command = try TouchCommand.parse(["100", "200"])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        await expectValidationError(contains: "No session found") {
            try await command.execute(on: client)
        }

        #expect(client.calls.map(\.name) == ["session_list"])
    }
}

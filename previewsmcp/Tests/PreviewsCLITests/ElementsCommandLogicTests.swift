import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `elements`'s daemon-relay logic (`ElementsCommand.execute(on:)`), tested
/// against a `FakeDaemonClient` — no daemon spawn, no simulator. Real
/// subprocess coverage (macOS-session error path, which depends on the
/// daemon's own policy) stays in `CLIIntegrationTests/ElementsCommandTests.swift`.
@Suite("elements daemon-relay logic")
struct ElementsCommandLogicTests {
    @Test("elements errors when no session is running")
    func elementsNoSession() async throws {
        let command = try ElementsCommand.parse([])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        await expectValidationError(contains: "No session found") {
            try await command.execute(on: client)
        }

        #expect(client.calls.map(\.name) == ["session_list"])
    }
}

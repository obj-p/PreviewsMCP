import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `switch`'s daemon-relay logic (`SwitchCommand.execute(on:)`), tested
/// against a `FakeDaemonClient` — no daemon spawn, no simulator. Real
/// subprocess coverage (active-preview round trip, out-of-range index,
/// which depend on the daemon's own behavior) stays in
/// `CLIIntegrationTests/SwitchCommandTests.swift`.
@Suite("switch daemon-relay logic")
struct SwitchCommandLogicTests {
    @Test("switch errors when no session is running")
    func switchNoSession() async throws {
        let command = try SwitchCommand.parse(["0"])
        let client = FakeDaemonClient(responses: ["session_list": .noSessions])

        await expectValidationError(contains: "No session found to switch") {
            try await command.execute(on: client)
        }

        #expect(client.calls.map(\.name) == ["session_list"])
    }

    @Test("switch surfaces a daemon-reported tool error")
    func switchDaemonError() async throws {
        let command = try SwitchCommand.parse(["0"])
        let client = FakeDaemonClient(responses: [
            "session_list": .foundSession,
            "preview_switch": .daemonError("preview index out of range"),
        ])

        await expectDaemonToolError(contains: "preview index out of range") {
            try await command.execute(on: client)
        }
    }
}

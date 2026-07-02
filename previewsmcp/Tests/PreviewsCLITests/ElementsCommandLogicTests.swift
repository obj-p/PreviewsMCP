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

    @Test("elements surfaces a daemon-reported tool error")
    func elementsDaemonError() async throws {
        let command = try ElementsCommand.parse([])
        let client = FakeDaemonClient(responses: [
            "session_list": .foundSession,
            "preview_elements": .daemonError("only available for iOS simulator previews"),
        ])

        await expectDaemonToolError(contains: "only available for iOS simulator previews") {
            try await command.execute(on: client)
        }
    }

    @Test("elements --json errors when the response has no structuredContent")
    func elementsJSONMissingStructuredContent() async throws {
        let command = try ElementsCommand.parse(["--json"])
        let client = FakeDaemonClient(responses: [
            "session_list": .foundSession,
            "preview_elements": CallTool.Result(content: [.text("[]")]),
        ])

        await expectDaemonToolError(contains: "missing structuredContent") {
            try await command.execute(on: client)
        }
    }
}

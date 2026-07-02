import Foundation
import MCP
@testable import PreviewsCLI
import Testing

/// `simulators`'s daemon-relay logic (`SimulatorsCommand.execute(on:)`),
/// tested against a `FakeDaemonClient` — no daemon spawn, no simulator.
/// Real subprocess coverage (device-line formatting against actual
/// CoreSimulator state, which needs real device data) stays in
/// `CLIIntegrationTests/SimulatorsCommandTests.swift`.
@Suite("simulators daemon-relay logic")
struct SimulatorsCommandLogicTests {
    @Test("simulators surfaces a daemon-reported tool error")
    func simulatorsDaemonError() async throws {
        let command = try SimulatorsCommand.parse([])
        let client = FakeDaemonClient(responses: [
            "simulator_list": .daemonError("CoreSimulator unavailable"),
        ])

        await expectDaemonToolError(contains: "CoreSimulator unavailable") {
            try await command.execute(on: client)
        }
    }

    @Test("simulators --json errors when the response has no structuredContent")
    func simulatorsJSONMissingStructuredContent() async throws {
        let command = try SimulatorsCommand.parse(["--json"])
        let client = FakeDaemonClient(responses: [
            "simulator_list": CallTool.Result(content: [.text("iPhone 16 — AAAA")]),
        ])

        await expectDaemonToolError(contains: "missing structuredContent") {
            try await command.execute(on: client)
        }
    }
}

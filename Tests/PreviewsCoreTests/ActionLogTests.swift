import Foundation
import Testing

@testable import PreviewsCore

@Suite("ActionLog")
struct ActionLogTests {

    @Test("Entries are returned in insertion order")
    func insertionOrder() async {
        let log = ActionLog()
        await log.append(
            tMs: 0, tool: "preview_touch",
            params: ["x": "100", "y": "200"], causedRecompile: false
        )
        await log.append(
            tMs: 500, tool: "preview_switch",
            params: ["previewIndex": "1"], causedRecompile: true
        )
        await log.append(
            tMs: 1200, tool: "preview_configure",
            params: ["colorScheme": "dark"], causedRecompile: true
        )
        let entries = await log.entries()
        #expect(entries.count == 3)
        #expect(entries[0].tool == "preview_touch")
        #expect(entries[1].tool == "preview_switch")
        #expect(entries[2].tool == "preview_configure")
    }

    @Test("Timestamps are monotonic")
    func monotonicTimestamps() async {
        let log = ActionLog()
        await log.append(tMs: 100, tool: "a", params: [:], causedRecompile: false)
        await log.append(tMs: 200, tool: "b", params: [:], causedRecompile: false)
        await log.append(tMs: 300, tool: "c", params: [:], causedRecompile: false)
        let entries = await log.entries()
        for i in 1..<entries.count {
            #expect(entries[i].tMs >= entries[i - 1].tMs)
        }
    }

    @Test("causedRecompile flag is preserved")
    func recompileFlag() async {
        let log = ActionLog()
        await log.append(tMs: 0, tool: "preview_touch", params: [:], causedRecompile: false)
        await log.append(tMs: 100, tool: "preview_configure", params: [:], causedRecompile: true)
        let entries = await log.entries()
        #expect(entries[0].causedRecompile == false)
        #expect(entries[1].causedRecompile == true)
    }

    @Test("Params are preserved")
    func paramsPreserved() async {
        let log = ActionLog()
        await log.append(
            tMs: 0, tool: "preview_touch",
            params: ["x": "100", "y": "200", "action": "tap"],
            causedRecompile: false
        )
        let entries = await log.entries()
        #expect(entries[0].params["x"] == "100")
        #expect(entries[0].params["y"] == "200")
        #expect(entries[0].params["action"] == "tap")
    }

    @Test("JSON round-trip preserves all fields")
    func jsonRoundTrip() async throws {
        let log = ActionLog()
        await log.append(
            tMs: 42, tool: "preview_touch",
            params: ["x": "100"], causedRecompile: false
        )
        await log.append(
            tMs: 850, tool: "preview_switch",
            params: ["previewIndex": "1"], causedRecompile: true
        )
        let entries = await log.entries()

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(entries)
        let decoded = try JSONDecoder().decode([ActionLogEntry].self, from: data)

        #expect(decoded.count == entries.count)
        for (original, roundTripped) in zip(entries, decoded) {
            #expect(original.tMs == roundTripped.tMs)
            #expect(original.tool == roundTripped.tool)
            #expect(original.params == roundTripped.params)
            #expect(original.causedRecompile == roundTripped.causedRecompile)
        }
    }

    @Test("Empty log returns empty array")
    func emptyLog() async {
        let log = ActionLog()
        let entries = await log.entries()
        #expect(entries.isEmpty)
    }
}

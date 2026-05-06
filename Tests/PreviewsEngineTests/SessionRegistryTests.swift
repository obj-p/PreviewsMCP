import Darwin
import Foundation
import Testing

@testable import PreviewsEngine

/// Round-trip + stale-PID-filter tests for the cross-process session
/// registry. These don't fork a real second process — they construct
/// two `SessionRegistry` instances pointing at the same fixture
/// directory but with different PIDs, simulating two PreviewsMCP
/// processes coordinating via the filesystem.
/// Used in place of the default `kill(pid, 0)` liveness check so the
/// fake PIDs we hand to test registries don't get filtered out as
/// stale on read. Tests that care about stale-PID behavior override
/// this back to the real check or a custom predicate.
@Sendable private func alwaysLive(_ pid: Int32) -> Bool { true }

@Suite("SessionRegistry")
struct SessionRegistryTests {

    // MARK: - publish round trip

    @Test("publishIOSSessions writes a file the peer can read")
    func iosRoundTrip() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_001)
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_002)

        await writer.publishIOSSessions([
            (id: "ios-A", sourceFile: URL(fileURLWithPath: "/tmp/A.swift"))
        ])

        let entries = await reader.readOthers()
        #expect(entries.count == 1)
        #expect(entries.first?.sessionID == "ios-A")
        #expect(entries.first?.platform == "ios")
        #expect(entries.first?.sourceFilePath == "/tmp/A.swift")
    }

    @Test("publishMacOSSessions writes a file the peer can read")
    func macRoundTrip() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_011)
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_012)

        await writer.publishMacOSSessions([
            (id: "mac-A", sourceFile: URL(fileURLWithPath: "/tmp/Mac.swift"))
        ])

        let entries = await reader.readOthers()
        #expect(entries.count == 1)
        #expect(entries.first?.sessionID == "mac-A")
        #expect(entries.first?.platform == "macos")
    }

    @Test("publish combines iOS and macOS slices in one file")
    func combinedSlices() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_021)
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_022)

        await writer.publishIOSSessions([
            (id: "ios-X", sourceFile: URL(fileURLWithPath: "/tmp/X.swift"))
        ])
        await writer.publishMacOSSessions([
            (id: "mac-Y", sourceFile: URL(fileURLWithPath: "/tmp/Y.swift"))
        ])

        let entries = await reader.readOthers().sorted { $0.sessionID < $1.sessionID }
        #expect(entries.map(\.sessionID) == ["ios-X", "mac-Y"])
        #expect(entries.map(\.platform) == ["ios", "macos"])
    }

    @Test("readOthers excludes the reader's own PID file")
    func excludesOwn() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_031)
        await writer.publishIOSSessions([
            (id: "self-only", sourceFile: URL(fileURLWithPath: "/tmp/me.swift"))
        ])

        // The same PID reads its own file via `readOthers` — must not see itself.
        let entries = await writer.readOthers()
        #expect(entries.isEmpty)
    }

    // MARK: - mutation behavior

    @Test("publishing an empty set leaves an empty file (peer sees no sessions)")
    func clearsByPublishingEmpty() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_041)
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_042)

        await writer.publishIOSSessions([
            (id: "ephemeral", sourceFile: URL(fileURLWithPath: "/tmp/e.swift"))
        ])
        #expect(await reader.readOthers().count == 1)

        await writer.publishIOSSessions([])
        #expect(await reader.readOthers().isEmpty)
    }

    @Test("unpublish removes the writer's file")
    func unpublishRemoves() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }

        let writer = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_051)
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: 100_052)

        await writer.publishIOSSessions([
            (id: "vanishing", sourceFile: URL(fileURLWithPath: "/tmp/v.swift"))
        ])
        #expect(await reader.readOthers().count == 1)

        await writer.unpublish()
        #expect(await reader.readOthers().isEmpty)

        // Idempotent — calling again must not throw.
        await writer.unpublish()
    }

    // MARK: - stale-PID filter

    @Test("readOthers drops files for non-existent PIDs and deletes them")
    func filtersStaleAndDeletes() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // PID 1 exists on macOS (launchd) but we use a definitely-dead
        // value via a fresh `Process()`'s PID after termination.
        let stalePID = makeStalePID()
        let staleFile = dir.appendingPathComponent("\(stalePID).json")
        let stalePayload =
            #"{"pid":\#(stalePID),"sessions":[{"sessionID":"ghost","platform":"ios","sourceFilePath":"/dev/null"}]}"#
        try stalePayload.write(to: staleFile, atomically: true, encoding: .utf8)

        // Use the default `kill(pid, 0)` predicate here so we exercise
        // the real stale-PID path.
        let reader = SessionRegistry(registryDir: dir, pid: 100_061)
        let entries = await reader.readOthers()
        #expect(entries.isEmpty, "stale-PID file must not contribute sessions")

        // Lazy cleanup: the stale file should be deleted on read.
        #expect(
            !FileManager.default.fileExists(atPath: staleFile.path),
            "readOthers() should garbage-collect the stale file"
        )
    }

    @Test("readOthers ignores files whose embedded PID doesn't match the filename")
    func filtersRecycledPID() async throws {
        let dir = makeFixture()
        defer { cleanup(dir) }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        // File named after a live PID (the test's own) but whose
        // embedded `pid` field disagrees — simulates a recycled PID
        // landing on someone else's leftover file before they had a
        // chance to overwrite it.
        let livePID = getpid()
        let payload = #"{"pid":999999,"sessions":[{"sessionID":"recycled","platform":"ios","sourceFilePath":"/x"}]}"#
        try payload.write(
            to: dir.appendingPathComponent("\(livePID).json"),
            atomically: true,
            encoding: .utf8
        )

        // Reader is a different PID so livePID is "other" from its
        // perspective — but the recycled-PID guard should skip it.
        let reader = SessionRegistry(registryDir: dir, liveCheck: alwaysLive, pid: livePID + 1)
        #expect(await reader.readOthers().isEmpty)
    }

    // MARK: - Fixtures

    private func makeFixture() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-registry-test-\(UUID().uuidString)")
    }

    private func cleanup(_ dir: URL) {
        try? FileManager.default.removeItem(at: dir)
    }

    /// A PID that is reliably not-running. We spawn `/bin/echo`, wait
    /// for it to exit, then return its PID. The kernel won't re-use
    /// the slot for the duration of the test.
    private func makeStalePID() -> Int32 {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/echo")
        proc.arguments = ["stale"]
        proc.standardOutput = Pipe()
        proc.standardError = Pipe()
        try? proc.run()
        proc.waitUntilExit()
        return proc.processIdentifier
    }
}

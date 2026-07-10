import Darwin
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct RespawnHandoffTests {
    private static func makeBuild(objectPath: URL, entrySymbol: String, dir: URL) -> JITRenderBuild {
        JITRenderBuild(
            objectPath: objectPath,
            imagePath: dir.appendingPathComponent("unused.png"),
            valuesPath: dir.appendingPathComponent("unused.json"),
            entrySymbol: entrySymbol,
            literals: []
        )
    }

    private static func pidReportingSource(entrySymbol: String, pidPath: String) -> String {
        """
        import Foundation

        @_cdecl("\(entrySymbol)")
        public func \(entrySymbol)() -> Int32 {
            let pid = String(ProcessInfo.processInfo.processIdentifier)
            do {
                try pid.write(toFile: "\(pidPath)", atomically: true, encoding: .utf8)
                return 0
            } catch {
                return -1
            }
        }
        """
    }

    private static func renderedPID(
        _ reloader: JITStructuralReloader, compiler: Compiler, dir: URL
    ) async throws -> (pid: Int32, build: JITRenderBuild) {
        let pidPath = dir.appendingPathComponent("gen1.pid").path
        let object = try await compiler.compileObject(
            source: Self.pidReportingSource(entrySymbol: "handoff_gen1", pidPath: pidPath),
            moduleName: "HandoffGen1Fixture"
        )
        let build = Self.makeBuild(objectPath: object, entrySymbol: "handoff_gen1", dir: dir)
        try await reloader.render(build)
        let text = try String(contentsOfFile: pidPath, encoding: .utf8)
        let pid = try #require(Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == 0)
        return (pid, build)
    }

    @Test func respawnKillsOldAgentOnlyAfterNewAgentRenders() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let compiler = try await Compiler()
        let reloader = JITStructuralReloader(generationCap: 1)
        let (oldPID, _) = try await Self.renderedPID(reloader, compiler: compiler, dir: dir)

        let probe = try await compiler.compileObject(
            source: """
            import Darwin

            @_cdecl("handoff_gen2")
            public func handoff_gen2() -> Int32 {
                kill(\(oldPID), 0) == 0 ? 0 : -9
            }
            """,
            moduleName: "HandoffGen2Fixture"
        )
        try await reloader.render(Self.makeBuild(objectPath: probe, entrySymbol: "handoff_gen2", dir: dir))
        #expect(kill(oldPID, 0) != 0)
    }

    @Test func failedRespawnKeepsOldAgentAndItsRenderAlive() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("handoff-fail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let compiler = try await Compiler()
        let reloader = JITStructuralReloader(generationCap: 1)
        let (oldPID, oldBuild) = try await Self.renderedPID(reloader, compiler: compiler, dir: dir)

        let failing = try await compiler.compileObject(
            source: """
            @_cdecl("handoff_fail")
            public func handoff_fail() -> Int32 { -7 }
            """,
            moduleName: "HandoffFailFixture"
        )
        await #expect(throws: (any Error).self) {
            try await reloader.render(Self.makeBuild(objectPath: failing, entrySymbol: "handoff_fail", dir: dir))
        }
        #expect(kill(oldPID, 0) == 0)
        try await reloader.render(oldBuild)
    }
}

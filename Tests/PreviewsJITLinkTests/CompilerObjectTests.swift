import PreviewsCore
import PreviewsJITLink
import Testing

struct CompilerObjectTests {
    @Test func compilesAndLinksObjectViaCompiler() async throws {
        let compiler = try await Compiler()
        let object = try await compiler.compileObject(
            source: """
            @_cdecl("compiler_answer")
            public func compilerAnswer() -> Int32 { 42 }
            """,
            moduleName: "CompilerObjectFixture"
        )

        let session = try JITSession()
        try session.addObject(path: object.path)
        let result: Int32 = try session.call(symbol: "compiler_answer")
        #expect(result == 42)
    }

    @Test func reResolvesSymbolAfterRecompile() async throws {
        let compiler = try await Compiler()

        let v1 = try await compiler.compileObject(
            source: """
            @_cdecl("reload_value")
            public func reloadValue() -> Int32 { 42 }
            """,
            moduleName: "ReloadFixture"
        )
        let v2 = try await compiler.compileObject(
            source: """
            @_cdecl("reload_value")
            public func reloadValue() -> Int32 { 43 }
            """,
            moduleName: "ReloadFixture"
        )

        let session1 = try JITSession()
        try session1.addObject(path: v1.path)
        let address1 = try session1.address(of: "reload_value")
        let result1: Int32 = try session1.call(symbol: "reload_value")

        let session2 = try JITSession()
        try session2.addObject(path: v2.path)
        let address2 = try session2.address(of: "reload_value")
        let result2: Int32 = try session2.call(symbol: "reload_value")

        #expect(result1 == 42)
        #expect(result2 == 43)
        #expect(address1 != address2)
    }
}

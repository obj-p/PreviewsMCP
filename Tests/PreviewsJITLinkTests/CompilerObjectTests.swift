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
}

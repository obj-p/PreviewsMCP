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

    @Test func rerendersAfterRecompileInFreshAgent() async throws {
        func renderSource(red: Int, green: Int, blue: Int) -> String {
            """
            import SwiftUI

            @_cdecl("compiler_render_value")
            public func compiler_render_value() -> Int32 {
                MainActor.assumeIsolated {
                    let content = Color(red: \(red), green: \(green), blue: \(blue))
                        .frame(width: 8, height: 8)
                    let renderer = ImageRenderer(content: content)
                    renderer.scale = 1
                    guard let cgImage = renderer.cgImage else { return Int32(-1) }
                    let rep = NSBitmapImageRep(cgImage: cgImage)
                    guard
                        let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                            .usingColorSpace(.deviceRGB)
                    else { return Int32(-2) }
                    let r = Int32((color.redComponent * 255).rounded())
                    let g = Int32((color.greenComponent * 255).rounded())
                    let b = Int32((color.blueComponent * 255).rounded())
                    return (r << 16) | (g << 8) | b
                }
            }
            """
        }

        let compiler = try await Compiler()

        let v1 = try await compiler.compileObject(
            source: renderSource(red: 1, green: 0, blue: 0),
            moduleName: "CompilerRenderFixture"
        )
        let v2 = try await compiler.compileObject(
            source: renderSource(red: 0, green: 0, blue: 1),
            moduleName: "CompilerRenderFixture"
        )

        let session1 = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session1.addObject(path: v1.path)
        let packed1 = try session1.runOnMain(symbol: "compiler_render_value")

        let session2 = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session2.addObject(path: v2.path)
        let packed2 = try session2.runOnMain(symbol: "compiler_render_value")

        #expect(packed1 >= 0)
        let r1 = (packed1 >> 16) & 0xFF
        let g1 = (packed1 >> 8) & 0xFF
        let b1 = packed1 & 0xFF
        #expect(r1 > 200 && g1 < 60 && b1 < 60)

        #expect(packed2 >= 0)
        let r2 = (packed2 >> 16) & 0xFF
        let g2 = (packed2 >> 8) & 0xFF
        let b2 = packed2 & 0xFF
        #expect(b2 > 200 && r2 < 60 && g2 < 60)
    }
}

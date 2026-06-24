import AppKit
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct JITStructuralReloaderTests {
    @Test func reloaderRendersCompileObjectForJIT() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI
        import AppKit

        struct ColorView: View {
            var body: some View {
                Color(red: 0, green: 1, blue: 0).frame(width: 8, height: 8)
            }
        }

        #Preview {
            ColorView()
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let build = try await session.compileObjectForJIT()

        let reloader = JITStructuralReloader()
        try await reloader.render(build)

        let data = try Data(contentsOf: build.imagePath)
        #expect(!data.isEmpty)
        let rep = try #require(NSBitmapImageRep(data: data))
        let color = try #require(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
        #expect(color.greenComponent > 0.8)
        #expect(color.redComponent < 0.2)
        #expect(color.blueComponent < 0.2)
    }

    @Test func literalRewriteReRendersSameObjectNoRecompile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34cii2-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("GrayView.swift")
        try """
        import SwiftUI
        import AppKit

        struct GrayView: View {
            var body: some View {
                Color(white: 0.2).frame(width: 8, height: 8)
            }
        }

        #Preview {
            GrayView()
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let build = try await session.compileObjectForJIT()
        let reloader = JITStructuralReloader()

        try await reloader.render(build)
        let b1 = try Self.centerBrightness(build.imagePath)
        #expect(b1 < 0.4)

        let whiteLiteral = try #require(
            build.literals.first { if case .float = $0.value { true } else { false } }
        )
        var values = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: build.valuesPath)) as? [String: Any]
        )
        values[whiteLiteral.id] = 0.9
        try JSONSerialization.data(withJSONObject: values).write(to: build.valuesPath)

        try await reloader.render(build)
        let b2 = try Self.centerBrightness(build.imagePath)
        #expect(b2 > 0.7)
        #expect(b2 > b1)
    }

    private static func centerBrightness(_ pngURL: URL) throws -> Double {
        let data = try Data(contentsOf: pngURL)
        guard
            let rep = NSBitmapImageRep(data: data),
            let color = rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
            .usingColorSpace(.deviceRGB)
        else {
            throw JITReloadError.renderFailed(status: -99)
        }
        return color.redComponent
    }
}

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
        try await reloader.renderObject(at: build.objectPath, entrySymbol: build.entrySymbol)

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
}

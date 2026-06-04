import AppKit
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct CappedPersistentTests {
    private static func renderSource(red: Int, green: Int, blue: Int) -> String {
        """
        import SwiftUI

        @_cdecl("persistent_render_value")
        public func persistent_render_value() -> Int32 {
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

    @Test func reusesOneSessionAcrossFreshGenerations() async throws {
        let compiler = try await Compiler()
        let colors = [(1, 0, 0), (0, 1, 0), (0, 0, 1), (1, 0, 0), (0, 1, 0)]
        var objects: [URL] = []
        for (r, g, b) in colors {
            objects.append(
                try await compiler.compileObject(
                    source: Self.renderSource(red: r, green: g, blue: b),
                    moduleName: "PersistentFixture"
                )
            )
        }

        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        for (index, object) in objects.enumerated() {
            if index > 0 { try session.newGeneration() }
            try session.addObject(path: object.path)
            let packed = Int(try session.runOnMain(symbol: "persistent_render_value"))
            #expect(packed >= 0)
            let r = (packed >> 16) & 0xFF
            let g = (packed >> 8) & 0xFF
            let b = packed & 0xFF
            let (er, eg, eb) = colors[index]
            #expect((er == 1) == (r > 200))
            #expect((eg == 1) == (g > 200))
            #expect((eb == 1) == (b > 200))
        }
    }
}

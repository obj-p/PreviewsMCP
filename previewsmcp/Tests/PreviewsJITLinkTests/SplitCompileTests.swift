import AppKit
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct SplitCompileTests {
    private static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    /// Bulk sources for the stable module. File 0 exposes the `bulkSquare` API the editable
    /// unit renders (so the split proves cross-module symbol use, not just a dangling import);
    /// files 1..<count are SwiftUI filler views that weight the whole-module baseline.
    private static func bulkSources(count: Int) -> [String] {
        var sources = [
            """
            import SwiftUI

            func bulkSquare(red: Double, green: Double, blue: Double) -> some View {
                Color(red: red, green: green, blue: blue).frame(width: 8, height: 8)
            }
            """,
        ]
        for i in 1 ..< count {
            sources.append(
                """
                import SwiftUI

                struct BulkView\(i): View {
                    let n = \(i)
                    var body: some View {
                        VStack(spacing: \(i % 7)) {
                            Text("bulk \(i)")
                            Color(red: 0.\(i % 9 + 1), green: 0.2, blue: 0.3)
                                .frame(width: \(8 + i % 5), height: \(8 + i % 3))
                            if n % 2 == 0 { Text("even") } else { Text("odd") }
                        }
                        .padding(\(i % 4))
                    }
                }
                """
            )
        }
        return sources
    }

    private static func editableUnit(green: Double) -> String {
        """
        import AppKit
        import SwiftUI

        @testable import SplitBulk

        @_cdecl("split_render_value")
        public func split_render_value() -> Int32 {
            MainActor.assumeIsolated {
                let content = bulkSquare(red: 1, green: \(green), blue: 0)
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

    private static func renderViaAgent(stable: Compiler.StableModule, editable: URL) throws -> Int {
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try session.addObject(path: stable.objectPath.path)
        try session.addObject(path: editable.path)
        return Int(try session.runOnMain(symbol: "split_render_value"))
    }

    @Test func editableUnitCompilesAgainstPrebuiltStableModuleAndRenders() async throws {
        let compiler = try await Compiler()
        let stable = try await compiler.emitStableModule(
            sources: Self.bulkSources(count: 8),
            moduleName: "SplitBulk"
        )

        let v1 = try await compiler.compileObject(
            source: Self.editableUnit(green: 0),
            moduleName: "SplitEdit",
            extraFlags: ["-I", stable.modulesDir.path]
        )
        let packed1 = try Self.renderViaAgent(stable: stable, editable: v1)
        #expect(packed1 >= 0)
        let r1 = (packed1 >> 16) & 0xFF
        let g1 = (packed1 >> 8) & 0xFF
        let b1 = packed1 & 0xFF
        #expect(r1 > 200 && g1 < 60 && b1 < 60)
    }

    @Test func structuralEditReusesStableModuleAcrossEdits() async throws {
        let compiler = try await Compiler()
        let stable = try await compiler.emitStableModule(
            sources: Self.bulkSources(count: 8),
            moduleName: "SplitBulk"
        )

        let v1 = try await compiler.compileObject(
            source: Self.editableUnit(green: 0),
            moduleName: "SplitEdit",
            extraFlags: ["-I", stable.modulesDir.path]
        )
        let packed1 = try Self.renderViaAgent(stable: stable, editable: v1)

        let v2 = try await compiler.compileObject(
            source: Self.editableUnit(green: 1),
            moduleName: "SplitEdit",
            extraFlags: ["-I", stable.modulesDir.path]
        )
        let packed2 = try Self.renderViaAgent(stable: stable, editable: v2)

        #expect(packed1 >= 0)
        let r1 = (packed1 >> 16) & 0xFF
        let g1 = (packed1 >> 8) & 0xFF
        let b1 = packed1 & 0xFF
        #expect(r1 > 200 && g1 < 60 && b1 < 60)

        #expect(packed2 >= 0)
        let r2 = (packed2 >> 16) & 0xFF
        let g2 = (packed2 >> 8) & 0xFF
        let b2 = packed2 & 0xFF
        #expect(r2 > 200 && g2 > 200 && b2 < 60)
    }

    /// The per-edit compile recompiles only the editable unit against the prebuilt stable
    /// module, so it does not grow with module size; the whole-module baseline does. With a
    /// realistic SwiftUI bulk the split is well under the baseline. (W5/W7: flat ~0.14s.)
    @Test func perEditRecompileIsBelowWholeModuleCompile() async throws {
        let count = 24
        let compiler = try await Compiler()
        let bulk = Self.bulkSources(count: count)
        let stable = try await compiler.emitStableModule(sources: bulk, moduleName: "SplitBulk")

        let clock = ContinuousClock()
        let s0 = clock.now
        _ = try await compiler.compileObject(
            source: Self.editableUnit(green: 1),
            moduleName: "SplitEdit",
            extraFlags: ["-I", stable.modulesDir.path]
        )
        let splitMs = Self.ms(s0.duration(to: clock.now))

        let wholeSource =
            bulk.joined(separator: "\n\n") + "\n\n"
                + Self.editableUnit(green: 1).replacingOccurrences(
                    of: "@testable import SplitBulk", with: ""
                )
        let w0 = clock.now
        _ = try await compiler.compileObject(source: wholeSource, moduleName: "SplitWhole")
        let wholeMs = Self.ms(w0.duration(to: clock.now))

        print(
            "P4.1 split compile (N=\(count)): editable-only=\(Int(splitMs))ms "
                + "whole-module=\(Int(wholeMs))ms"
        )
        #expect(splitMs < wholeMs)
    }
}

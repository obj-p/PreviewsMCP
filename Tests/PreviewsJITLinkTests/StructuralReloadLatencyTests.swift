import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct StructuralReloadLatencyTests {
    private static func ms(_ duration: Duration) -> Double {
        let c = duration.components
        return Double(c.seconds) * 1000 + Double(c.attoseconds) / 1e15
    }

    @Test func measuresStructuralReloadLatency() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34d-\(UUID().uuidString)", isDirectory: true)
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
        let reloader = JITStructuralReloader()

        // Warm up: first compile pays module-cache warmup, first agent pays spawn cost.
        let warm = try await session.compileObjectForJIT()
        try await reloader.render(warm)

        let clock = ContinuousClock()
        let t0 = clock.now
        let build = try await session.compileObjectForJIT()
        let t1 = clock.now
        try await reloader.render(build)
        let t2 = clock.now

        let compileMs = Self.ms(t0.duration(to: t1))
        let renderMs = Self.ms(t1.duration(to: t2))
        print(
            "P3.4d structural reload (small module, respawn-per-edit): "
                + "compile=\(Int(compileMs))ms render=\(Int(renderMs))ms "
                + "total=\(Int(compileMs + renderMs))ms"
        )

        #expect(compileMs + renderMs < 30000)
    }
}

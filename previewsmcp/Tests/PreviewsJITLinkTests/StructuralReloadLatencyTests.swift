import Foundation
@testable import PreviewsCore
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

    @Test func driverBypassProducesEquivalentObjectAndIsFaster() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbypass-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bulkFile = dir.appendingPathComponent("bulk_0.swift")
        try "func bulkValue() -> Int32 { 42 }\n"
            .write(to: bulkFile, atomically: true, encoding: .utf8)

        /// The overlay references a bulk declaration (two-way resolution) and the token forces a
        /// textually different source each edit, so the driver recompiles instead of no-opping.
        func overlay(_ token: Int32) -> String {
            "@_cdecl(\"answer\") func answer() -> Int32 { bulkValue() + \(token) - \(token) }\n"
        }
        // Correctness: the driver path and the frontend-bypass path both produce a working object.
        let driverCompiler = try await Compiler()
        let driverBuild = try await driverCompiler.compileModuleIncremental(
            overlaySource: overlay(0), bulkFiles: [bulkFile], moduleName: "DBypass",
            bypassDriver: false
        )
        #expect(try linkedAnswer(driverBuild) == 42)

        let bypassCompiler = try await Compiler()
        // First call seeds the template via the driver; the second exercises the frontend bypass.
        _ = try await bypassCompiler.compileModuleIncremental(
            overlaySource: overlay(0), bulkFiles: [bulkFile], moduleName: "DBypass",
            bypassDriver: true
        )
        let bypassBuild = try await bypassCompiler.compileModuleIncremental(
            overlaySource: overlay(1), bulkFiles: [bulkFile], moduleName: "DBypass",
            bypassDriver: true
        )
        #expect(try linkedAnswer(bypassBuild) == 42)

        // Latency: comparative, so it self-normalizes for machine load. Each edit changes the
        // overlay so both paths actually recompile it.
        func median(_ values: [Double]) -> Double {
            values.sorted()[values.count / 2]
        }
        let clock = ContinuousClock()
        var driverMs: [Double] = []
        var bypassMs: [Double] = []
        for i in 0 ..< 5 {
            let token = Int32(i + 2)
            let d0 = clock.now
            _ = try await driverCompiler.compileModuleIncremental(
                overlaySource: overlay(token), bulkFiles: [bulkFile], moduleName: "DBypass",
                bypassDriver: false
            )
            driverMs.append(Self.ms(d0.duration(to: clock.now)))

            let b0 = clock.now
            _ = try await bypassCompiler.compileModuleIncremental(
                overlaySource: overlay(token), bulkFiles: [bulkFile], moduleName: "DBypass",
                bypassDriver: true
            )
            bypassMs.append(Self.ms(b0.duration(to: clock.now)))
        }
        let driverMedian = median(driverMs)
        let bypassMedian = median(bypassMs)
        print(
            "driver-bypass: driver median=\(Int(driverMedian))ms "
                + "bypass median=\(Int(bypassMedian))ms "
                + "driver=\(driverMs.map { Int($0) }) bypass=\(bypassMs.map { Int($0) })"
        )

        #expect(bypassMedian < driverMedian)
        #expect(bypassMedian < 30000)
    }

    @Test func rebuildsBulkObjectWhenBulkFileChanges() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("dbypass-bulk-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let bulkFile = dir.appendingPathComponent("bulk_0.swift")
        let overlay = "@_cdecl(\"answer\") func answer() -> Int32 { bulkValue() }\n"

        try "func bulkValue() -> Int32 { 42 }\n"
            .write(to: bulkFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        // Seed the template, then take the bypass path; both see bulkValue() == 42.
        _ = try await compiler.compileModuleIncremental(
            overlaySource: overlay, bulkFiles: [bulkFile], moduleName: "BulkChange", bypassDriver: true
        )
        let before = try await compiler.compileModuleIncremental(
            overlaySource: overlay, bulkFiles: [bulkFile], moduleName: "BulkChange", bypassDriver: true
        )
        #expect(try linkedAnswer(before) == 42)

        // Change a bulk file out of band (the overlay is unchanged). The bypass only rebuilds the
        // overlay, so without busting the cache it would reuse the stale bulk object and still
        // return 42. The mtime in the fingerprint must force the driver to rebuild bulk -> 99.
        try "func bulkValue() -> Int32 { 99 }\n"
            .write(to: bulkFile, atomically: true, encoding: .utf8)
        let after = try await compiler.compileModuleIncremental(
            overlaySource: overlay, bulkFiles: [bulkFile], moduleName: "BulkChange", bypassDriver: true
        )
        #expect(try linkedAnswer(after) == 99)
    }

    private func linkedAnswer(_ build: (overlayObject: URL, bulkObjects: [URL])) throws -> Int32 {
        let session = try JITSession()
        for object in build.bulkObjects {
            try session.addObject(path: object.path)
        }
        try session.addObject(path: build.overlayObject.path)
        return try session.call(symbol: "answer")
    }
}

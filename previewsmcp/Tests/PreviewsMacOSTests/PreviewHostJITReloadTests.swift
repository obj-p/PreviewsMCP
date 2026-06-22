import Foundation
import PreviewsCore
import Testing

@testable import PreviewsMacOS

@MainActor
@Suite("PreviewHost JIT structural reload")
struct PreviewHostJITReloadTests {

    final class RecordingReloader: StructuralReloader, @unchecked Sendable {
        private(set) var calls: [(objectPath: URL, entrySymbol: String)] = []
        func render(_ build: JITRenderBuild) async throws {
            calls.append((objectPath: build.objectPath, entrySymbol: build.entrySymbol))
        }
    }

    @Test func structuralReloadRecordsAgentImage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3a-\(UUID().uuidString)", isDirectory: true)
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

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        host.watchFile(sessionID: "s1", session: session, filePath: sourceFile.path, compiler: compiler)

        let imagePath = try await host.jitStructuralReload(sessionID: "s1", session: session)
        #expect(host.agentSnapshotPath(for: "s1") == imagePath)
        #expect(reloader.calls.count == 1)
        #expect(reloader.calls.first?.entrySymbol == "renderPreviewToFile")
    }

    @Test func sessionsGetSeparateReloadersAndCloseReleasesThem() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        var made: [RecordingReloader] = []
        let host = PreviewHost(makeStructuralReloader: {
            let reloader = RecordingReloader()
            made.append(reloader)
            return reloader
        })
        host.watchFile(sessionID: "a", session: session, filePath: sourceFile.path, compiler: compiler)
        host.watchFile(sessionID: "b", session: session, filePath: sourceFile.path, compiler: compiler)

        _ = try await host.jitStructuralReload(sessionID: "a", session: session)
        _ = try await host.jitStructuralReload(sessionID: "b", session: session)
        #expect(made.count == 2)
        #expect(made.first !== made.last)
        #expect(made.first?.calls.count == 1)
        #expect(made.last?.calls.count == 1)

        _ = try await host.jitStructuralReload(sessionID: "a", session: session)
        #expect(made.count == 2)
        #expect(made.first?.calls.count == 2)

        weak var first = made.first
        made.removeFirst()
        host.closePreview(sessionID: "a")
        #expect(first == nil)
        #expect(host.agentSnapshotPath(for: "a") == nil)
        #expect(host.agentSnapshotPath(for: "b") != nil)
    }

    @Test func literalReloadRewritesValuesAndRecordsImage() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34cii3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("HelloView.swift")
        try """
        import SwiftUI

        struct HelloView: View {
            var body: some View {
                Text("hello")
            }
        }

        #Preview {
            HelloView()
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let build = try await session.compileObjectForJIT()

        let host = PreviewHost(makeStructuralReloader: { RecordingReloader() })
        host.watchFile(sessionID: "s1", session: session, filePath: sourceFile.path, compiler: compiler)

        let stringLiteral = try #require(
            build.literals.first { if case .string = $0.value { return true } else { return false } }
        )
        let img = try await host.jitLiteralReload(
            sessionID: "s1",
            session: session,
            changes: [(id: stringLiteral.id, newValue: .string("world"))]
        )

        #expect(img == build.imagePath)
        #expect(host.agentSnapshotPath(for: "s1") == build.imagePath)

        let values = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: build.valuesPath)) as? [String: Any]
        )
        #expect((values[stringLiteral.id] as? String) == "world")
    }

    @Test func jitStartBakesRequestedSpecWithoutDaemonWindow() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let host = PreviewHost(makeStructuralReloader: { RecordingReloader() })

        try await host.jitStart(
            sessionID: "visible", session: session,
            title: "Preview: ColorView.swift",
            size: NSSize(width: 320, height: 240), headless: false)
        #expect(host.agentSnapshotPath(for: "visible") != nil)
        let spec = try #require(host.agentWindowSpec(for: "visible"))
        #expect(spec.title == "Preview: ColorView.swift")
        #expect(spec.width == 320)
        #expect(spec.height == 240)

        try await host.jitStart(
            sessionID: "hidden", session: session,
            title: "ignored", size: NSSize(width: 320, height: 240), headless: true)
        let hiddenSpec = try #require(host.agentWindowSpec(for: "hidden"))
        #expect(hiddenSpec.headless)
        #expect(hiddenSpec.width == 320)
        #expect(hiddenSpec.height == 240)
        #expect(host.agentSnapshotPath(for: "hidden") != nil)

        host.closePreview(sessionID: "visible")
        #expect(host.agentWindowSpec(for: "visible") == nil)
    }

    @Test func closedSessionNeverGetsANewAgent() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3f-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        var madeCount = 0
        let host = PreviewHost(makeStructuralReloader: {
            madeCount += 1
            return RecordingReloader()
        })

        try await host.jitStart(
            sessionID: "s", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true)
        #expect(madeCount == 1)
        #expect(host.allSessions["s"] != nil)

        host.closePreview(sessionID: "s")
        let build = try await session.compileObjectForJIT()
        await #expect(throws: (any Error).self) {
            try await host.jitRender(sessionID: "s", build: build)
        }
        #expect(madeCount == 1)
        let literal = try await host.jitLiteralReload(sessionID: "s", session: session, changes: [])
        #expect(literal == nil)
        #expect(madeCount == 1)
    }
}

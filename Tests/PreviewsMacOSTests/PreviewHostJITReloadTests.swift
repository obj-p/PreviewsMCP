import Foundation
import PreviewsCore
import Testing

@testable import PreviewsMacOS

@MainActor
@Suite("PreviewHost JIT structural reload")
struct PreviewHostJITReloadTests {

    final class RecordingReloader: StructuralReloader, @unchecked Sendable {
        private(set) var calls: [(objectPath: URL, entrySymbol: String)] = []
        func renderObject(
            at objectPath: URL, supportObjectPaths: [URL], archivePaths: [URL], entrySymbol: String
        ) async throws {
            calls.append((objectPath: objectPath, entrySymbol: entrySymbol))
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

        let host = PreviewHost()
        let reloader = RecordingReloader()
        host.structuralReloader = reloader

        let imagePath = try await host.jitStructuralReload(sessionID: "s1", session: session)
        #expect(imagePath != nil)
        #expect(host.agentSnapshotPath(for: "s1") == imagePath)
        #expect(reloader.calls.count == 1)
        #expect(reloader.calls.first?.entrySymbol == "renderPreviewToFile")
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

        let host = PreviewHost()
        host.structuralReloader = RecordingReloader()

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

    @Test func noReloaderFallsThrough() async throws {
        let host = PreviewHost()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci3a-nil-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let sourceFile = dir.appendingPathComponent("Empty.swift")
        try "import SwiftUI\n".write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let imagePath = try await host.jitStructuralReload(sessionID: "s2", session: session)
        #expect(imagePath == nil)
        #expect(host.agentSnapshotPath(for: "s2") == nil)
    }
}

import Foundation
import PreviewsCore
import Testing

@testable import PreviewsMacOS

@MainActor
@Suite("PreviewHost JIT structural reload")
struct PreviewHostJITReloadTests {

    final class RecordingReloader: StructuralReloader, @unchecked Sendable {
        private(set) var calls: [(objectPath: URL, entrySymbol: String)] = []
        func renderObject(at objectPath: URL, entrySymbol: String) async throws {
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

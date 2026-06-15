import Foundation
import Testing

@testable import PreviewsCore

@Suite("iOS compileObjectForJIT")
struct IOSCompileObjectForJITTests {
    @Test("compiles an iOS-triple object carrying the renderPreviewToFile entry")
    func compilesIOSObjectWithRenderEntry() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ios-jit-object-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("Preview.swift")
        try """
            import SwiftUI

            struct TestView: View {
                var body: some View {
                    Text("Hello")
                }
            }

            #Preview { TestView() }
            """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler(platform: .iOS)
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler, platform: .iOS)
        let build = try await session.compileObjectForJIT()

        #expect(build.entrySymbol == "renderPreviewToFile")
        #expect(FileManager.default.fileExists(atPath: build.objectPath.path))

        let symbols = try await runAsync("/usr/bin/nm", arguments: [build.objectPath.path])
        #expect(symbols.stdout.contains("renderPreviewToFile"))
    }
}

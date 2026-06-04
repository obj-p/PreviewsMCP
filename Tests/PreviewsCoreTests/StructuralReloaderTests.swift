import Foundation
import Testing

@testable import PreviewsCore

@Suite("StructuralReloader seam")
struct StructuralReloaderTests {

    private actor MockReloader: StructuralReloader {
        private(set) var calls: [(objectPath: URL, entrySymbol: String)] = []
        func renderObject(at objectPath: URL, entrySymbol: String) async throws {
            calls.append((objectPath: objectPath, entrySymbol: entrySymbol))
        }
        func recorded() -> [(objectPath: URL, entrySymbol: String)] { calls }
    }

    @Test("compileObjectForJIT emits a linkable .o carrying renderPreviewToFile")
    func compilesJITObject() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p34ci-\(UUID().uuidString)", isDirectory: true)
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
        #expect(build.entrySymbol == "renderPreviewToFile")
        #expect(FileManager.default.fileExists(atPath: build.objectPath.path))

        let symbols = try Self.symbols(in: build.objectPath)
        #expect(symbols.contains("_renderPreviewToFile"))

        let reloader = MockReloader()
        try await reloader.renderObject(at: build.objectPath, entrySymbol: build.entrySymbol)
        let calls = await reloader.recorded()
        #expect(calls.count == 1)
        #expect(calls.first?.objectPath == build.objectPath)
        #expect(calls.first?.entrySymbol == "renderPreviewToFile")
    }

    private static func symbols(in object: URL) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = ["-gU", object.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

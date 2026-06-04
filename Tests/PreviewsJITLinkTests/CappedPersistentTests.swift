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

    private static func designTimeStoreSymbols(in object: URL) throws -> Set<String> {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/nm")
        process.arguments = [object.path]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        let names = text.split(separator: "\n").compactMap { line -> String? in
            line.split(separator: " ").last.map(String.init)
        }
        return Set(names.filter { $0.hasPrefix("_$s") && $0.contains("DesignTimeStore") })
    }

    @Test func editableModuleNameIsUniquePerCompile() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("unique-mod-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color(red: 0, green: 1, blue: 0).frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let b1 = try await session.compileObjectForJIT()
        let b2 = try await session.compileObjectForJIT()

        let s1 = try Self.designTimeStoreSymbols(in: b1.objectPath)
        let s2 = try Self.designTimeStoreSymbols(in: b2.objectPath)
        #expect(!s1.isEmpty)
        #expect(s1.isDisjoint(with: s2))
    }

    @Test func reloaderRespawnsAtGenerationCap() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("capped-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color(red: 0, green: 1, blue: 0).frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let reloader = JITStructuralReloader(generationCap: 2)

        for _ in 0..<5 {
            let build = try await session.compileObjectForJIT()
            try await reloader.renderObject(
                at: build.objectPath,
                supportObjectPaths: build.supportObjectPaths,
                archivePaths: build.archivePaths,
                dylibPaths: build.dylibPaths,
                entrySymbol: build.entrySymbol
            )
            let data = try Data(contentsOf: build.imagePath)
            #expect(!data.isEmpty)
        }
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

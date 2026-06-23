import AppKit
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

struct PreviewSessionSplitTests {
    private struct Project {
        let dir: URL
        let hotFile: URL
        let context: BuildContext
    }

    /// Lay down a temp Tier-2 project: a stable "bulk" file exposing a `Palette` the preview
    /// consumes cross-module, plus the hot preview file. `BuildContext.sourceFiles` excludes
    /// the hot file (matching the build systems), so it is the stable bulk.
    private static func makeProject(previewBody: String) throws -> Project {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("split-session-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)

        let paletteFile = dir.appendingPathComponent("Palette.swift")
        try """
        import SwiftUI

        struct Palette {
            static func square(red: Double, green: Double, blue: Double) -> some View {
                Color(red: red, green: green, blue: blue).frame(width: 8, height: 8)
            }
        }
        """.write(to: paletteFile, atomically: true, encoding: .utf8)

        let hotFile = dir.appendingPathComponent("PreviewView.swift")
        try """
        import SwiftUI

        #Preview {
            \(previewBody)
        }
        """.write(to: hotFile, atomically: true, encoding: .utf8)

        let context = BuildContext(
            moduleName: "DemoApp",
            compilerFlags: [],
            projectRoot: dir,
            targetName: "DemoApp",
            sourceFiles: [paletteFile]
        )
        return Project(dir: dir, hotFile: hotFile, context: context)
    }

    private static func renderColor(_ build: JITRenderBuild) throws -> NSColor {
        let session = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        for object in build.supportObjectPaths {
            try session.addObject(path: object.path)
        }
        try session.addObject(path: build.objectPath.path)
        let status = try session.runOnMain(symbol: build.entrySymbol)
        #expect(status == 0)

        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: build.imagePath)))
        return try #require(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
    }

    @Test func splitCompileRendersHotFileAgainstStableBulk() async throws {
        let project = try Self.makeProject(
            previewBody: "Palette.square(red: 1, green: 0, blue: 0)"
        )
        defer { try? FileManager.default.removeItem(at: project.dir) }

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: project.hotFile, compiler: compiler, buildContext: project.context
        )

        let build = try await session.compileObjectForJIT()
        #expect(!build.supportObjectPaths.isEmpty)

        let color = try Self.renderColor(build)
        #expect(color.redComponent > 0.8)
        #expect(color.greenComponent < 0.2)
        #expect(color.blueComponent < 0.2)
    }

    @Test func stableModuleCachedAcrossHotEditsAndInvalidatedByBulkChange() async throws {
        let project = try Self.makeProject(
            previewBody: "Palette.square(red: 1, green: 0, blue: 0)"
        )
        defer { try? FileManager.default.removeItem(at: project.dir) }

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: project.hotFile, compiler: compiler, buildContext: project.context
        )

        let build1 = try await session.compileObjectForJIT()

        try """
        import SwiftUI

        #Preview {
            Palette.square(red: 0, green: 1, blue: 0)
        }
        """.write(to: project.hotFile, atomically: true, encoding: .utf8)
        let build2 = try await session.compileObjectForJIT()

        #expect(!build1.supportObjectPaths.isEmpty)
        #expect(build1.supportObjectPaths == build2.supportObjectPaths)

        let bulkFile = project.dir.appendingPathComponent("Palette.swift")
        try """
        import SwiftUI

        struct Palette {
            static let tag = 7
            static func square(red: Double, green: Double, blue: Double) -> some View {
                Color(red: red, green: green, blue: blue).frame(width: 8, height: 8)
            }
        }
        """.write(to: bulkFile, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: 5)], ofItemAtPath: bulkFile.path
        )
        let build3 = try await session.compileObjectForJIT()

        #expect(build3.supportObjectPaths != build2.supportObjectPaths)
    }

    @Test func reloaderRendersSplitBuildThroughBothObjects() async throws {
        let project = try Self.makeProject(
            previewBody: "Palette.square(red: 1, green: 0, blue: 0)"
        )
        defer { try? FileManager.default.removeItem(at: project.dir) }

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: project.hotFile, compiler: compiler, buildContext: project.context
        )
        let build = try await session.compileObjectForJIT()

        let reloader = JITStructuralReloader()
        try await reloader.render(build)

        let rep = try #require(NSBitmapImageRep(data: Data(contentsOf: build.imagePath)))
        let color = try #require(
            rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                .usingColorSpace(.deviceRGB)
        )
        #expect(color.redComponent > 0.8)
        #expect(color.greenComponent < 0.2)
        #expect(color.blueComponent < 0.2)
    }

    @Test func structuralEditReRendersThroughSplit() async throws {
        let project = try Self.makeProject(
            previewBody: "Palette.square(red: 1, green: 0, blue: 0)"
        )
        defer { try? FileManager.default.removeItem(at: project.dir) }

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: project.hotFile, compiler: compiler, buildContext: project.context
        )

        let red = try await session.compileObjectForJIT()
        let redColor = try Self.renderColor(red)
        #expect(redColor.redComponent > 0.8 && redColor.greenComponent < 0.2)

        try """
        import SwiftUI

        #Preview {
            Palette.square(red: 0, green: 0, blue: 1)
        }
        """.write(to: project.hotFile, atomically: true, encoding: .utf8)

        let blue = try await session.compileObjectForJIT()
        let blueColor = try Self.renderColor(blue)
        #expect(blueColor.blueComponent > 0.8 && blueColor.redComponent < 0.2)
    }
}

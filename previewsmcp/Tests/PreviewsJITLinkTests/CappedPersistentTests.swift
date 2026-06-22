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
            try await reloader.render(build)
            let data = try Data(contentsOf: build.imagePath)
            #expect(!data.isEmpty)
        }
    }

    @Test func bridgeReusesPreviewWindowAcrossGenerations() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-reuse-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        var builds: [JITRenderBuild] = []
        for body in ["Color.red", "Color.blue"] {
            try """
            import SwiftUI

            #Preview {
                \(body).frame(width: 8, height: 8)
            }
            """.write(to: sourceFile, atomically: true, encoding: .utf8)
            builds.append(try await session.compileObjectForJIT())
        }

        let probe = try await compiler.compileObject(
            source: """
                import AppKit

                @_cdecl("preview_window_probe")
                public func preview_window_probe() -> Int32 {
                    MainActor.assumeIsolated {
                        Int32(
                            NSApplication.shared.windows.filter {
                                $0.identifier?.rawValue == "previewsmcp-preview"
                            }.count)
                    }
                }
                """,
            moduleName: "WindowProbeFixture"
        )

        let agent = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        for (index, build) in builds.enumerated() {
            if index > 0 { try agent.newGeneration() }
            try agent.addObject(path: build.objectPath.path)
            #expect(try agent.runOnMain(symbol: build.entrySymbol) == 0)
            let rep = try #require(
                NSBitmapImageRep(data: Data(contentsOf: build.imagePath)))
            let color = try #require(
                rep.colorAt(x: rep.pixelsWide / 2, y: rep.pixelsHigh / 2)?
                    .usingColorSpace(.deviceRGB))
            #expect((index == 0) == (color.redComponent > 0.5))
            #expect((index == 1) == (color.blueComponent > 0.5))
        }
        try agent.newGeneration()
        try agent.addObject(path: probe.path)
        #expect(try agent.runOnMain(symbol: "preview_window_probe") == 1)
    }

    @Test func bridgeAppliesWindowSpecOnCreation() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("window-spec-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.green.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let build = try await session.compileObjectForJIT(
            window: JITRenderWindow(
                x: -9000, y: -9000, width: 320, height: 240,
                title: "Preview: ColorView.swift"))

        let probe = try await compiler.compileObject(
            source: """
                import AppKit

                @_cdecl("preview_window_spec_probe")
                public func preview_window_spec_probe() -> Int32 {
                    MainActor.assumeIsolated {
                        guard
                            let window = NSApplication.shared.windows.first(where: {
                                $0.identifier?.rawValue == "previewsmcp-preview"
                            })
                        else { return -1 }
                        var bits: Int32 = 0
                        if window.title == "Preview: ColorView.swift" { bits |= 1 }
                        if abs(window.frame.width - 320) < 1 { bits |= 2 }
                        if let content = window.contentView,
                            abs(content.bounds.height - 240) < 1
                        {
                            bits |= 4
                        }
                        if window.styleMask.contains(.titled) { bits |= 8 }
                        return bits
                    }
                }
                """,
            moduleName: "WindowSpecProbeFixture"
        )

        let agent = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try agent.addObject(path: build.objectPath.path)
        #expect(try agent.runOnMain(symbol: build.entrySymbol) == 0)
        try agent.newGeneration()
        try agent.addObject(path: probe.path)
        let bits = try agent.runOnMain(symbol: "preview_window_spec_probe")
        #expect(bits == 15, "bits=\(bits)")
    }

    @Test func bridgeRecordsWindowFrameOnMoveAndResize() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("frame-record-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.green.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)
        let build = try await session.compileObjectForJIT(
            window: JITRenderWindow(
                x: -9000, y: -9000, width: 320, height: 240,
                title: "Preview: ColorView.swift"))

        let sidecar = PreviewSession.frameSidecarPath(for: session.id)
        try? FileManager.default.removeItem(at: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let probe = try await compiler.compileObject(
            source: """
                import AppKit

                @_cdecl("preview_move_probe")
                public func preview_move_probe() -> Int32 {
                    MainActor.assumeIsolated {
                        guard
                            let window = NSApplication.shared.windows.first(where: {
                                $0.identifier?.rawValue == "previewsmcp-preview"
                            })
                        else { return -1 }
                        window.setFrame(
                            NSRect(x: -8000, y: -7000, width: 321, height: 654), display: false)
                        return 0
                    }
                }
                """,
            moduleName: "FrameMoveProbeFixture"
        )

        let agent = try JITSession(remoteAgentPath: JITSession.bundledAgentPath())
        try agent.addObject(path: build.objectPath.path)
        #expect(try agent.runOnMain(symbol: build.entrySymbol) == 0)
        try agent.newGeneration()
        try agent.addObject(path: probe.path)
        #expect(try agent.runOnMain(symbol: "preview_move_probe") == 0)

        let frame = try #require(PreviewSession.storedWindowFrame(for: session.id))
        #expect(frame.width == 321)
        #expect(frame.height == 654)
        #expect(frame.x != -9000)
        #expect(frame.y != -9000)
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

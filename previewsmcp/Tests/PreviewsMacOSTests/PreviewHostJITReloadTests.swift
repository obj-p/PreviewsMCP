import Foundation
import PreviewsCore
@testable import PreviewsMacOS
import Testing

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
        try await host.jitStart(
            sessionID: "a", session: session,
            title: "a", size: NSSize(width: 8, height: 8), headless: true
        )
        try await host.jitStart(
            sessionID: "b", session: session,
            title: "b", size: NSSize(width: 8, height: 8), headless: true
        )
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
            build.literals.first { if case .string = $0.value { true } else { false } }
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
            size: NSSize(width: 320, height: 240), headless: false
        )
        #expect(host.agentSnapshotPath(for: "visible") != nil)
        let spec = try #require(host.agentWindowSpec(for: "visible"))
        #expect(spec.title == "Preview: ColorView.swift")
        #expect(spec.width == 320)
        #expect(spec.height == 240)

        try await host.jitStart(
            sessionID: "hidden", session: session,
            title: "ignored", size: NSSize(width: 320, height: 240), headless: true
        )
        let hiddenSpec = try #require(host.agentWindowSpec(for: "hidden"))
        #expect(hiddenSpec.headless)
        #expect(hiddenSpec.width == 320)
        #expect(hiddenSpec.height == 240)
        #expect(host.agentSnapshotPath(for: "hidden") != nil)

        host.closePreview(sessionID: "visible")
        #expect(host.agentWindowSpec(for: "visible") == nil)
    }

    @Test func restoreBakesRecordedContentRectAndCarriesKey() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p254r-\(UUID().uuidString)", isDirectory: true)
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
        let sidecar = PreviewSession.frameSidecarPath(for: session.id)
        try? FileManager.default.removeItem(at: sidecar)
        defer { try? FileManager.default.removeItem(at: sidecar) }

        let host = PreviewHost(makeStructuralReloader: { RecordingReloader() })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "Preview: ColorView.swift",
            size: NSSize(width: 320, height: 240), headless: false
        )

        let recorded: [String: Any] = [
            "x": 100.0, "y": 200.0, "width": 400.0, "height": 600.0, "key": false,
        ]
        try JSONSerialization.data(withJSONObject: recorded).write(to: sidecar)

        try await host.jitStructuralReload(sessionID: "s1", session: session)

        let spec = try #require(host.agentWindowSpec(for: "s1"))
        #expect(spec.x == 100)
        #expect(spec.y == 200)
        #expect(spec.width == 400)
        #expect(spec.height == 600)
        #expect(!spec.activate)
        #expect(PreviewSession.storedWindowFrame(for: session.id)?.isKey == false)
    }

    @Test func unchangedSourceFireDoesNotReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p297u-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)
        let primary = FileWatcher.canonicalPath(sourceFile.path) ?? sourceFile.path

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
        #expect(reloader.calls.count == 1)

        // The watcher fires for the primary file but its content did not change
        // (a no-op save, mtime touch, or atomic-rename replay). No reload, so @State survives.
        await host.handleWatchedChange(
            sessionID: "s1", canonicalPrimary: primary, firedPaths: [primary]
        )
        #expect(reloader.calls.count == 1, "unchanged source must not trigger a reload")
    }

    @Test func primaryLiteralOnlyFireRerendersWithoutStructuralReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p297l-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("HelloView.swift")
        let original = """
        import SwiftUI

        struct HelloView: View {
            var body: some View { Text("hello") }
        }

        #Preview {
            HelloView()
        }
        """
        try original.write(to: sourceFile, atomically: true, encoding: .utf8)
        let primary = FileWatcher.canonicalPath(sourceFile.path) ?? sourceFile.path

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
        #expect(reloader.calls.count == 1)
        let originalSnapshot = host.agentSnapshotPath(for: "s1")

        let edited = original.replacingOccurrences(of: "hello", with: "world")
        try edited.write(to: sourceFile, atomically: true, encoding: .utf8)

        await host.handleWatchedChange(
            sessionID: "s1", canonicalPrimary: primary, firedPaths: [primary]
        )

        #expect(reloader.calls.count == 2, "literal-only edit should re-render the existing object")
        #expect(
            reloader.calls.first?.objectPath == reloader.calls.last?.objectPath,
            "literal-only edit must not compile a new object"
        )
        #expect(host.agentSnapshotPath(for: "s1") == originalSnapshot)
        guard case .unchanged = await session.classifySourceChange(newSource: edited) else {
            Issue.record("successful literal reload should commit the edited source baseline")
            return
        }
    }

    @Test func primaryStructuralFireRunsStructuralReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p297s-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        let original = """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """
        try original.write(to: sourceFile, atomically: true, encoding: .utf8)
        let primary = FileWatcher.canonicalPath(sourceFile.path) ?? sourceFile.path

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
        #expect(reloader.calls.count == 1)

        let edited = original.replacingOccurrences(
            of: ".frame(width: 8, height: 8)",
            with: ".frame(width: 8, height: 8).padding(1)"
        )
        try edited.write(to: sourceFile, atomically: true, encoding: .utf8)

        await host.handleWatchedChange(
            sessionID: "s1", canonicalPrimary: primary, firedPaths: [primary]
        )

        #expect(reloader.calls.count == 2, "structural primary edit must structurally reload")
    }

    @Test func secondaryFileFireForcesStructuralReload() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p297x-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)
        let secondaryFile = dir.appendingPathComponent("Helper.swift")
        try "import SwiftUI\n".write(to: secondaryFile, atomically: true, encoding: .utf8)
        let primary = FileWatcher.canonicalPath(sourceFile.path) ?? sourceFile.path
        let secondary = FileWatcher.canonicalPath(secondaryFile.path) ?? secondaryFile.path

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
        #expect(reloader.calls.count == 1)

        // A cross-file dependency changed while the primary stayed byte-identical. Only a
        // structural recompile picks the edit up, so the unchanged shortcut must not skip it.
        await host.handleWatchedChange(
            sessionID: "s1", canonicalPrimary: primary, firedPaths: [secondary]
        )
        #expect(reloader.calls.count == 2, "a secondary-file change must force a structural reload")
    }

    @Test func coalescedBurstWithUnchangedPrimaryStillStructural() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("p297b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let sourceFile = dir.appendingPathComponent("ColorView.swift")
        try """
        import SwiftUI

        #Preview {
            Color.red.frame(width: 8, height: 8)
        }
        """.write(to: sourceFile, atomically: true, encoding: .utf8)
        let secondaryFile = dir.appendingPathComponent("Helper.swift")
        try "import SwiftUI\n".write(to: secondaryFile, atomically: true, encoding: .utf8)
        let primary = FileWatcher.canonicalPath(sourceFile.path) ?? sourceFile.path
        let secondary = FileWatcher.canonicalPath(secondaryFile.path) ?? secondaryFile.path

        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: sourceFile, compiler: compiler)

        let reloader = RecordingReloader()
        let host = PreviewHost(makeStructuralReloader: { reloader })
        try await host.jitStart(
            sessionID: "s1", session: session,
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
        #expect(reloader.calls.count == 1)

        // One coalesced burst reports both the unchanged primary and a changed secondary.
        // The secondary in the set must force structural so the cross-file edit is not dropped.
        await host.handleWatchedChange(
            sessionID: "s1", canonicalPrimary: primary, firedPaths: [primary, secondary]
        )
        #expect(reloader.calls.count == 2, "a co-changed secondary in the burst must force structural")
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
            title: "t", size: NSSize(width: 8, height: 8), headless: true
        )
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

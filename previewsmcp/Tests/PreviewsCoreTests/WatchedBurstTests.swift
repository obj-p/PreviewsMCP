import Foundation
@testable import PreviewsCore
import Testing

/// Stage-4 burst tiering (docs/state-invalidation.md): bursts touching
/// captured evidence re-run the producer chain; bursts confined to the
/// primary file and existing target sources keep today's classification.
@Suite("Watched burst tiering")
struct WatchedBurstTests {
    private struct Fixture {
        let session: PreviewSession
        let primary: String
        let primarySource: String
        let targetSource: String
        let sourceRoot: String
        let runtimeInput: String
        let definitionFile: String
        let root: URL
    }

    private func makeFixture() async throws -> Fixture {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burst-\(UUID().uuidString)")
        let sourcesDir = root.appendingPathComponent("Sources/Target")
        let resourcesDir = root.appendingPathComponent("Resources")
        try FileManager.default.createDirectory(
            at: sourcesDir, withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: resourcesDir, withIntermediateDirectories: true
        )

        let primary = sourcesDir.appendingPathComponent("Primary.swift")
        let primarySource = "struct P {}"
        try primarySource.write(to: primary, atomically: true, encoding: .utf8)
        let targetSource = sourcesDir.appendingPathComponent("Helper.swift")
        try "struct H {}".write(to: targetSource, atomically: true, encoding: .utf8)
        let runtimeInput = resourcesDir.appendingPathComponent("logo.txt")
        try "v1".write(to: runtimeInput, atomically: true, encoding: .utf8)
        let definitionFile = root.appendingPathComponent("Package.swift")
        try "// package".write(to: definitionFile, atomically: true, encoding: .utf8)

        func canonical(_ url: URL) throws -> String {
            try #require(FileWatcher.canonicalPath(url.path))
        }
        let evidence = EvidenceSet(
            sourceDirectories: [URL(fileURLWithPath: try canonical(sourcesDir))],
            runtimeInputs: [URL(fileURLWithPath: try canonical(runtimeInput))],
            definitionFiles: [URL(fileURLWithPath: try canonical(definitionFile))]
        )
        let context = BuildContext(
            moduleName: "Target",
            compilerFlags: [],
            projectRoot: root,
            targetName: "Target",
            sourceFiles: [targetSource],
            evidence: evidence
        )
        let session = PreviewSession(
            sourceFile: primary,
            compiler: try await Compiler(),
            buildContext: context
        )
        await session.commitSourceBaseline(primarySource)
        return Fixture(
            session: session,
            primary: try canonical(primary),
            primarySource: primarySource,
            targetSource: try canonical(targetSource),
            sourceRoot: try canonical(sourcesDir),
            runtimeInput: try canonical(runtimeInput),
            definitionFile: try canonical(definitionFile),
            root: root
        )
    }

    private func classify(
        _ f: Fixture, fired: Set<String>
    ) async -> PreviewSession.WatchedBurstAction {
        await f.session.classifyWatchedBurst(
            firedPaths: fired,
            canonicalPrimary: f.primary,
            newPrimarySource: f.primarySource
        )
    }

    @Test("A definition-file fire re-resolves, and wins over lower tiers")
    func definitionFireReresolves() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        guard case .reresolve = await classify(
            f, fired: [f.definitionFile, f.runtimeInput, f.primary]
        ) else {
            Issue.record("expected .reresolve")
            return
        }
    }

    @Test("A runtime-input fire refreshes")
    func runtimeInputFireRefreshes() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        guard case .refresh = await classify(f, fired: [f.runtimeInput]) else {
            Issue.record("expected .refresh")
            return
        }
    }

    @Test("A file added under a source root refreshes")
    func addedSourceFileRefreshes() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let added = "\(f.sourceRoot)/Added.swift"
        try "struct A {}".write(
            to: URL(fileURLWithPath: added), atomically: true, encoding: .utf8
        )

        guard case .refresh = await classify(f, fired: [added]) else {
            Issue.record("expected .refresh")
            return
        }
    }

    @Test("An edit to an existing captured target source stays on the fast path")
    func targetSourceEditStaysFastPath() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        guard case let .fastPath(kind) = await classify(f, fired: [f.targetSource]),
              case .structural = kind
        else {
            Issue.record("expected .fastPath(.structural)")
            return
        }
    }

    @Test("A removed captured target source refreshes (source list is stale)")
    func targetSourceRemovalRefreshes() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        try FileManager.default.removeItem(atPath: f.targetSource)

        guard case .refresh = await classify(f, fired: [f.targetSource]) else {
            Issue.record("expected .refresh")
            return
        }
    }

    @Test("A primary-only fire with unchanged content is a fast-path no-op")
    func primaryOnlyUnchanged() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        guard case let .fastPath(kind) = await classify(f, fired: [f.primary]),
              case .unchanged = kind
        else {
            Issue.record("expected .fastPath(.unchanged)")
            return
        }
    }

    @Test("An identical-content refire of an evidence path is damped")
    func identicalRefireDamped() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        guard case .refresh = await classify(f, fired: [f.runtimeInput]) else {
            Issue.record("expected first fire to .refresh")
            return
        }
        guard case let .fastPath(kind) = await classify(f, fired: [f.runtimeInput]),
              case .unchanged = kind
        else {
            Issue.record("expected identical refire to damp to .fastPath(.unchanged)")
            return
        }
        try "v2".write(
            to: URL(fileURLWithPath: f.runtimeInput), atomically: true, encoding: .utf8
        )
        guard case .refresh = await classify(f, fired: [f.runtimeInput]) else {
            Issue.record("expected a real content change to .refresh again")
            return
        }
    }

    @Test("replaceBuildContext re-derives the captured target-source set")
    func replaceBuildContextRederivesTargets() async throws {
        let f = try await makeFixture()
        defer { try? FileManager.default.removeItem(at: f.root) }

        let added = "\(f.sourceRoot)/Added.swift"
        try "struct A {}".write(
            to: URL(fileURLWithPath: added), atomically: true, encoding: .utf8
        )
        guard case .refresh = await classify(f, fired: [added]) else {
            Issue.record("expected the uncaptured file to .refresh")
            return
        }

        let recaptured = BuildContext(
            moduleName: "Target",
            compilerFlags: [],
            projectRoot: f.root,
            targetName: "Target",
            sourceFiles: [
                URL(fileURLWithPath: f.targetSource), URL(fileURLWithPath: added),
            ],
            evidence: EvidenceSet(
                sourceDirectories: [URL(fileURLWithPath: f.sourceRoot)]
            )
        )
        await f.session.replaceBuildContext(recaptured)

        try "struct A2 {}".write(
            to: URL(fileURLWithPath: added), atomically: true, encoding: .utf8
        )
        guard case let .fastPath(kind) = await classify(f, fired: [added]),
              case .structural = kind
        else {
            Issue.record("expected the newly captured file to stay on the fast path")
            return
        }
    }

    @Test("Without evidence the burst keeps today's classification")
    func noEvidenceDelegates() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("burst-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = root.appendingPathComponent("Primary.swift")
        try "struct P {}".write(to: primary, atomically: true, encoding: .utf8)

        let session = PreviewSession(sourceFile: primary, compiler: try await Compiler())
        await session.commitSourceBaseline("struct P {}")
        let canonicalPrimary = try #require(FileWatcher.canonicalPath(primary.path))

        guard case let .fastPath(kind) = await session.classifyWatchedBurst(
            firedPaths: ["\(root.path)/Other.swift"],
            canonicalPrimary: canonicalPrimary,
            newPrimarySource: "struct P {}"
        ), case .structural = kind else {
            Issue.record("expected .fastPath(.structural)")
            return
        }
    }
}

@Suite("Watch-set derivation")
struct WatchSetTests {
    @Test("Missing files and missing directory roots are dropped, not fatal")
    func missingEntriesDropped() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchset-\(UUID().uuidString)")
        let liveDir = root.appendingPathComponent("Sources/Live")
        try FileManager.default.createDirectory(at: liveDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let primary = liveDir.appendingPathComponent("Primary.swift")
        try "p".write(to: primary, atomically: true, encoding: .utf8)

        let derived = WatchSet.derive(
            primary: primary.path,
            buildContext: BuildContext(
                moduleName: "M", compilerFlags: [], projectRoot: root, targetName: "T",
                sourceFiles: [root.appendingPathComponent("Gone.swift")],
                evidence: EvidenceSet(
                    sourceDirectories: [liveDir, root.appendingPathComponent("Sources/Gone")],
                    runtimeInputs: [root.appendingPathComponent("gone.json")]
                )
            )
        )
        #expect(derived.paths == [primary.path])
        #expect(derived.directories.map(\.root) == [liveDir.path])

        let watcher = try FileWatcher(
            paths: derived.paths, directories: derived.directories
        ) { _ in }
        watcher.stop()
    }

    @Test("A directory-only watch set installs")
    func directoryOnlyWatchInstalls() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("watchset-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let watcher = try FileWatcher(
            paths: [],
            directories: [.init(root: root.path, extensions: ["swift"])]
        ) { _ in }
        watcher.stop()
    }
}

@Suite("Fired-path damper")
struct FiredPathDamperTests {
    private func makeFile(_ content: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("damper-\(UUID().uuidString).txt")
        try content.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    @Test("First fire is real; identical refire is damped; change is real")
    func contentTransitions() throws {
        let file = try makeFile("v1")
        defer { try? FileManager.default.removeItem(at: file) }
        var damper = FiredPathDamper()

        let firstFire = damper.isRealChange(file.path)
        let identicalRefire = damper.isRealChange(file.path)
        try "v2".write(to: file, atomically: true, encoding: .utf8)
        let contentChange = damper.isRealChange(file.path)
        let changedRefire = damper.isRealChange(file.path)
        #expect(firstFire)
        #expect(!identicalRefire)
        #expect(contentChange)
        #expect(!changedRefire)
    }

    @Test("Disappearance and reappearance are real changes")
    func presenceTransitions() throws {
        let file = try makeFile("v1")
        var damper = FiredPathDamper()

        let firstFire = damper.isRealChange(file.path)
        try FileManager.default.removeItem(at: file)
        let disappearance = damper.isRealChange(file.path)
        let stillAbsent = damper.isRealChange(file.path)
        try "v1".write(to: file, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: file) }
        let reappearance = damper.isRealChange(file.path)
        #expect(firstFire)
        #expect(disappearance)
        #expect(!stillAbsent)
        #expect(reappearance)
    }
}

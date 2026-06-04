import AppKit
import Foundation
import PreviewsCore
import PreviewsJITLink
import Testing

/// End-to-end validation that the P4.1 recompile-narrowing split works against a real SPM
/// example: a real `BuildContext` from `SPMBuildSystem` (real `-I`/`-L`/`-package-name`
/// flags, real multi-file target, sibling + cross-package deps), driven through
/// `PreviewSession.compileObjectForJIT()`.
///
/// The split COMPILE is validated here. Rendering a real Tier-2 preview in the agent is
/// blocked on G3 (the JIT agent does not yet load the target's dependency archives
/// `libToDoExtras.a` / `libLocalDep.a` — their symbols are unresolved at JIT-link time);
/// the render test below is disabled until G3 lands. See `docs/jit-executor-phase3-plan.md`.
@Suite(.serialized)
struct ExamplesSplitE2ETests {
    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PreviewsJITLinkTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root
    static let spmRoot = repoRoot.appendingPathComponent("examples/spm")

    enum E2EError: Error { case noBuildSystem }

    static func context(for hotFile: URL) async throws -> BuildContext {
        guard let spm = try await SPMBuildSystem.detect(for: hotFile) else {
            throw E2EError.noBuildSystem
        }
        return try await spm.build(platform: .macOS)
    }

    @Test func splitCompilesRealCrossFilePreviewWithDeps() async throws {
        let hot = Self.spmRoot.appendingPathComponent("Sources/ToDo/Summary.swift")
        let ctx = try await Self.context(for: hot)
        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: hot, compiler: compiler, buildContext: ctx)

        let build = try await session.compileObjectForJIT()

        #expect(!build.supportObjectPaths.isEmpty)
        #expect(FileManager.default.fileExists(atPath: build.objectPath.path))
        for support in build.supportObjectPaths {
            #expect(FileManager.default.fileExists(atPath: support.path))
        }
        #expect(build.entrySymbol == "renderPreviewToFile")
    }

    @Test func literalUpdateClassifiedOnRealPreview() async throws {
        let hot = Self.spmRoot.appendingPathComponent("Sources/ToDo/BadgePreview.swift")
        let ctx = try await Self.context(for: hot)
        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: hot, compiler: compiler, buildContext: ctx)

        let build1 = try await session.compileObjectForJIT()

        let original = try String(contentsOf: hot, encoding: .utf8)
        let edited = original.replacingOccurrences(of: "In Progress", with: "Reviewing")
        #expect(edited != original)

        let changes = try #require(await session.tryLiteralUpdate(newSource: edited))
        #expect(!changes.isEmpty)

        let build2 = try #require(try await session.applyLiteralValuesForJIT(changes))
        #expect(build2.objectPath == build1.objectPath)
    }

    @Test(
        .disabled(
            "G3: JIT agent does not yet load the target's dependency archives (libToDoExtras.a / libLocalDep.a); their symbols are unresolved at JIT-link time. Enable once G3 lands."
        ))
    func splitRendersRealPreviewInAgent() async throws {
        let hot = Self.spmRoot.appendingPathComponent("Sources/ToDo/Summary.swift")
        let ctx = try await Self.context(for: hot)
        let compiler = try await Compiler()
        let session = PreviewSession(sourceFile: hot, compiler: compiler, buildContext: ctx)
        let build = try await session.compileObjectForJIT()

        let reloader = JITStructuralReloader()
        try await reloader.renderObject(
            at: build.objectPath,
            supportObjectPaths: build.supportObjectPaths,
            entrySymbol: build.entrySymbol
        )
        let png = try Data(contentsOf: build.imagePath)
        #expect(!png.isEmpty)
        #expect(NSBitmapImageRep(data: png) != nil)
    }
}

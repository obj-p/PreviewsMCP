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
/// The split COMPILE is validated here, and G3-a (static dependency archives) now lets the
/// agent resolve archived sibling/cross-package symbols (ToDoExtras / LocalDep). Rendering a
/// real Tier-2 preview is still blocked on G3-b (dlopen the target's binary frameworks, e.g.
/// Lottie, in the agent) and G3-c (the compiler-rt builtin `___isPlatformVersionAtLeast`
/// emitted by `#available`); the render test below stays disabled until those land. See
/// `docs/jit-executor-phase3-plan.md`.
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
            "G3-a (static archives) lands here and resolves ToDoExtras/LocalDep. Still blocked: the stable module bundles ToDoView.swift, which uses the Lottie binary framework (needs G3-b: dlopen the framework in the agent) and emits `___isPlatformVersionAtLeast` from #available (needs G3-c: the compiler-rt builtin). Enable once G3-b/G3-c land."
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
            archivePaths: build.archivePaths,
            entrySymbol: build.entrySymbol
        )
        let png = try Data(contentsOf: build.imagePath)
        #expect(!png.isEmpty)
        #expect(NSBitmapImageRep(data: png) != nil)
    }
}

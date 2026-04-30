import Foundation
import Testing

@testable import PreviewsCore

@Suite("PreviewSession with BuildContext", .serialized)
struct PreviewSessionBuildContextTests {

    // MARK: - Paths

    static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // PreviewsCoreTests/
        .deletingLastPathComponent()  // Tests/
        .deletingLastPathComponent()  // repo root

    static let spmExampleRoot = repoRoot.appendingPathComponent("examples/spm")
    static let toDoViewFile = spmExampleRoot.appendingPathComponent("Sources/ToDo/ToDoView.swift")

    // MARK: - Helpers

    static func buildSPMExample() async throws -> BuildContext {
        guard let spm = try await SPMBuildSystem.detect(for: toDoViewFile) else {
            throw TestHelperError.noBuildSystem
        }
        return try await spm.build(platform: .macOS)
    }

    static func tier1Context(from ctx: BuildContext) -> BuildContext {
        BuildContext(
            moduleName: ctx.moduleName,
            compilerFlags: ctx.compilerFlags,
            projectRoot: ctx.projectRoot,
            targetName: ctx.targetName,
            sourceFiles: nil
        )
    }

    enum TestHelperError: Error, LocalizedError {
        case noBuildSystem

        var errorDescription: String? {
            switch self {
            case .noBuildSystem:
                return "SPMBuildSystem.detect returned nil for examples/spm"
            }
        }
    }

    // MARK: - Tests

    @Test("SPM build context surfaces dependency libs for sibling and cross-package targets (#69)")
    func spmLinksDependencyTargets() async throws {
        let ctx = try await Self.buildSPMExample()

        let flags = ctx.compilerFlags
        #expect(
            flags.contains("-L"),
            "SPMBuildSystem should add -L <binPath> after swift build"
        )
        // Sibling target inside the same Package.swift
        #expect(
            flags.contains("-lToDoExtras"),
            "SPMBuildSystem should archive and link sibling target deps; flags were: \(flags)"
        )
        // Cross-package dependency resolved via .package(path: "LocalDep")
        #expect(
            flags.contains("-lLocalDep"),
            "SPMBuildSystem should archive and link cross-package path deps; flags were: \(flags)"
        )
        // The consumer target itself must not be linked as -lToDo; Tier 2 compiles
        // those sources directly and a second copy would cause duplicate-symbol errors.
        #expect(
            !flags.contains("-lToDo"),
            "Consumer target should not be linked as a library"
        )
        // Binary XCFramework dependency (lottie-spm) — SPM copies .framework bundles
        // into binPath instead of producing .build/ directories with loose .o files.
        #expect(
            flags.contains("-F"),
            "SPMBuildSystem should add -F <binPath> for binary framework deps; flags were: \(flags)"
        )
        #expect(
            flags.contains("-framework"),
            "SPMBuildSystem should add -framework flags for binary deps; flags were: \(flags)"
        )
        // Verify the actual framework name is emitted, not just the flag.
        if let idx = flags.firstIndex(of: "-framework") {
            #expect(
                idx + 1 < flags.count && flags[idx + 1] == "Lottie",
                "Expected -framework Lottie; flags were: \(flags)"
            )
        }
        #expect(
            flags.contains("-rpath"),
            "SPMBuildSystem should add -rpath for framework dlopen; flags were: \(flags)"
        )
        // Package-access: SPM passes `-package-name <identity>` to every
        // swiftc invocation in the package. The dylib recompile must carry
        // the same flag for `package`-scoped symbols to remain visible
        // across module boundaries. For `examples/spm/` SPM derives the
        // identity as "spm" (lowercased directory basename).
        #expect(
            flags.contains("-package-name"),
            "SPMBuildSystem should forward -package-name from .build/debug.yaml; flags were: \(flags)"
        )
        if let idx = flags.firstIndex(of: "-package-name") {
            #expect(
                idx + 1 < flags.count && flags[idx + 1] == "spm",
                "Expected -package-name spm; flags were: \(flags)"
            )
        }
    }

    @Test("Tier 2 compile: dylib + populated literals + DesignTimeStore symbols")
    func tier2Compile() async throws {
        let ctx = try await Self.buildSPMExample()
        #expect(ctx.supportsTier2)
        #expect(
            ctx.sourceFiles?.contains(where: { $0.lastPathComponent == "Item.swift" }) == true)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: Self.toDoViewFile,
            previewIndex: 0,
            compiler: compiler,
            buildContext: ctx
        )

        let result = try await session.compile()
        #expect(FileManager.default.fileExists(atPath: result.dylibPath.path))
        #expect(!result.literals.isEmpty, "Tier 2 should produce literal mappings")

        let loader = try DylibLoader(path: result.dylibPath.path)
        typealias CreateFunc = @convention(c) () -> UnsafeMutableRawPointer
        let _: CreateFunc = try loader.symbol(name: "createPreviewView")
        typealias SetString = @convention(c) (UnsafePointer<CChar>, UnsafePointer<CChar>) -> Void
        let _: SetString = try loader.symbol(name: "designTimeSetString")
        typealias SetInt = @convention(c) (UnsafePointer<CChar>, Int) -> Void
        let _: SetInt = try loader.symbol(name: "designTimeSetInteger")
    }

    @Test("Tier 1 context has supportsTier2 == false")
    func tier1ContextProperties() {
        let ctx = BuildContext(
            moduleName: "TestModule",
            compilerFlags: ["-I", "/some/path"],
            projectRoot: URL(fileURLWithPath: "/tmp"),
            targetName: "TestModule",
            sourceFiles: nil
        )
        #expect(!ctx.supportsTier2)
        #expect(ctx.sourceFiles == nil)
    }

    @Test("tryLiteralUpdate returns nil for Tier 1 session")
    func tryLiteralUpdateNilForTier1() async throws {
        let fullCtx = try await Self.buildSPMExample()
        let ctx = Self.tier1Context(from: fullCtx)

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: Self.toDoViewFile,
            previewIndex: 0,
            compiler: compiler,
            buildContext: ctx
        )

        // No compile needed — tryLiteralUpdate checks buildContext.supportsTier2
        // before checking lastOriginalSource
        let original = try String(contentsOf: Self.toDoViewFile, encoding: .utf8)
        #expect(original.contains("\"My Items\""), "ToDoView.swift should contain \"My Items\"")
        let modified = original.replacingOccurrences(of: "\"My Items\"", with: "\"My Tasks\"")

        let changes = await session.tryLiteralUpdate(newSource: modified)
        #expect(changes == nil, "Tier 1 should always return nil from tryLiteralUpdate")
    }

    @Test("tryLiteralUpdate returns changes for Tier 2 session")
    func tryLiteralUpdateChangesForTier2() async throws {
        let ctx = try await Self.buildSPMExample()

        let compiler = try await Compiler()
        let session = PreviewSession(
            sourceFile: Self.toDoViewFile,
            previewIndex: 0,
            compiler: compiler,
            buildContext: ctx
        )

        _ = try await session.compile()

        let original = try String(contentsOf: Self.toDoViewFile, encoding: .utf8)
        #expect(original.contains("\"My Items\""), "ToDoView.swift should contain \"My Items\"")
        let modified = original.replacingOccurrences(of: "\"My Items\"", with: "\"My Tasks\"")

        let changes = await session.tryLiteralUpdate(newSource: modified)
        #expect(changes != nil, "Tier 2 should detect literal-only change")
        #expect(
            changes?.contains(where: { $0.newValue == .string("My Tasks") }) == true,
            "Should contain the changed string value"
        )
    }

    // MARK: - Dynamic library product exclusion

    /// Regression guard for the swift-issue-reporting / `Testing.framework`
    /// bug (PR #146). Minimal SPM shape that reproduces the necessary
    /// artifact layout: a root package with a sibling `.library(type:
    /// .dynamic)` product that the consumer target does NOT import. SPM
    /// emits both `lib<Sibling>.dylib` and `<Sibling>.build/` in binPath,
    /// and before the fix `archiveDependencyTargets` unconditionally added
    /// `-l<Sibling>` to the preview link — the linker then preferred the
    /// `.dylib` over our `.a`, dragging an unrelated dynamic product (and
    /// its transitive deps) into the preview host. In the real-world case
    /// the dynamic product was `IssueReportingTestSupport`, whose load
    /// command on `Testing.framework` killed the iOS-simulator preview
    /// host at dlopen.
    ///
    /// We use a synthetic fixture rather than the real `swift-issue-reporting`
    /// package because plain `swift build` on a root package that only
    /// imports `IssueReporting` does not emit `libIssueReportingTestSupport.dylib`
    /// — SPM only materialises that dylib when the product is explicitly
    /// requested, which PreviewsMCP's build path does not do. The synthetic
    /// fixture controls the shape directly.
    @Test("SPMBuildSystem does not -l a sibling dynamic library product")
    func spmSkipsDynamicLibraryProductFromLink() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("previewsmcp-dynlib-test-\(UUID().uuidString)")
        let consumerDir = tmpDir.appendingPathComponent("Sources/ConsumerLib")
        let siblingDir = tmpDir.appendingPathComponent("Sources/SiblingDyn")
        try FileManager.default.createDirectory(at: consumerDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: siblingDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let packageSwift = """
            // swift-tools-version: 6.0
            import PackageDescription

            let package = Package(
                name: "Fixture",
                platforms: [.macOS(.v14)],
                products: [
                    .library(name: "ConsumerLib", targets: ["ConsumerLib"]),
                    .library(name: "SiblingDyn", type: .dynamic, targets: ["SiblingDyn"]),
                ],
                targets: [
                    .target(name: "SiblingDyn", path: "Sources/SiblingDyn"),
                    .target(name: "ConsumerLib", path: "Sources/ConsumerLib"),
                ]
            )
            """
        try packageSwift.write(
            to: tmpDir.appendingPathComponent("Package.swift"),
            atomically: true, encoding: .utf8)
        try "public func siblingHello() -> String { \"hi\" }".write(
            to: siblingDir.appendingPathComponent("SiblingDyn.swift"),
            atomically: true, encoding: .utf8)
        let consumerFile = consumerDir.appendingPathComponent("ConsumerLib.swift")
        try "public func consumerHello() -> String { \"hi\" }".write(
            to: consumerFile, atomically: true, encoding: .utf8)

        let buildSystem = SPMBuildSystem(projectRoot: tmpDir, sourceFile: consumerFile)
        let context = try await buildSystem.build(platform: .macOS)

        // Load-bearing sanity check: the "-lSiblingDyn absent" assertion only
        // proves the fix when the fixture actually produced the dylib whose
        // presence triggers the skip. Without it, a future SPM behaviour
        // change that stops emitting the sibling dylib would turn this test
        // green for the wrong reason.
        let binPathResult = try await runAsync(
            "/usr/bin/env",
            arguments: ["swift", "build", "--show-bin-path"],
            workingDirectory: tmpDir,
            discardStderr: true
        )
        let binPath = URL(
            fileURLWithPath: binPathResult.stdout.trimmingCharacters(
                in: .whitespacesAndNewlines))
        let dylibPath = binPath.appendingPathComponent("libSiblingDyn.dylib")
        #expect(
            FileManager.default.fileExists(atPath: dylibPath.path),
            "fixture should produce libSiblingDyn.dylib — without it the -l absence below is meaningless"
        )

        #expect(
            !context.compilerFlags.contains("-lSiblingDyn"),
            "compilerFlags should not -l a sibling dynamic library product; flags were: \(context.compilerFlags)"
        )
    }
}

import Foundation
@testable import PreviewsCore
import Testing

/// Stage-3 EvidenceSet derivation (docs/state-invalidation.md): the
/// classifier's product-root exclusion (prefix-based against derived
/// roots, never name fragments), the guarded source-root derivation with
/// its parent-directory fallback, the per-node roots from a SwiftPM
/// llbuild manifest (dependency nodes included, fetched dependencies and
/// generated sources excluded), copy-tool resource inputs, and the Bazel
/// per-action source grouping.
@Suite("Evidence set derivation")
struct EvidenceSetTests {
    private func makeWorkspace() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("evidence-\(UUID().uuidString)")
        let files = [
            "App/Package.swift",
            "App/Package.resolved",
            "App/Sources/App/Main.swift",
            "App/Sources/App/Helper.swift",
            "App/Sources/App/Resources/value.txt",
            "Dep/Package.swift",
            "Dep/Sources/Dep/Shared.swift",
            "App/.build/checkouts/Fetched/Sources/Fetched/F.swift",
            "App/.build/plugins/outputs/generated/Gen.swift",
        ]
        for file in files {
            let url = root.appendingPathComponent(file)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try "// \(file)".write(to: url, atomically: true, encoding: .utf8)
        }
        return root
    }

    private func scratch(_ root: URL) -> [URL] {
        [EvidenceClassifier.productRoot(root.appendingPathComponent("App/.build"))]
    }

    private func canonical(_ root: URL, _ path: String) -> URL {
        URL(fileURLWithPath: FileWatcher.canonicalPath(
            root.appendingPathComponent(path).path
        )!)
    }

    @Test("classifier excludes product-root paths and missing files")
    func classifierExcludesProducts() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let products = scratch(root)

        #expect(EvidenceClassifier.evidencePath(
            root.appendingPathComponent("App/Sources/App/Main.swift"), productRoots: products
        ) != nil)
        #expect(EvidenceClassifier.evidencePath(
            root.appendingPathComponent("App/.build/checkouts/Fetched/Sources/Fetched/F.swift"),
            productRoots: products
        ) == nil)
        #expect(EvidenceClassifier.evidencePath(
            root.appendingPathComponent("App/Sources/App/Missing.swift"), productRoots: products
        ) == nil)
    }

    @Test("a marker-like name outside the product roots stays evidence")
    func markerLikeNamesAreNotExcluded() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }
        let odd = root.appendingPathComponent("App/Sources/DerivedData/Odd.swift")
        try FileManager.default.createDirectory(
            at: odd.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try "// odd".write(to: odd, atomically: true, encoding: .utf8)

        #expect(EvidenceClassifier.evidencePath(odd, productRoots: scratch(root)) != nil)
    }

    @Test("common directory is the deepest shared ancestor")
    func commonDirectory() {
        let common = EvidenceClassifier.commonDirectory(of: [
            URL(fileURLWithPath: "/w/App/Sources/App/Main.swift"),
            URL(fileURLWithPath: "/w/App/Sources/App/Nested/Deep.swift"),
        ])
        #expect(common?.path == "/w/App/Sources/App")
    }

    @Test("a root that would contain a product root degrades to safe parents")
    func firehoseRootDegradesToParents() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        // The two survivors' common ancestor is the App package root,
        // which contains .build — the forbidden firehose root. The
        // fallback keeps Main.swift's parent and drops Package.swift's
        // parent (the package root itself).
        let roots = EvidenceClassifier.sourceRoots(
            forGroups: [[
                root.appendingPathComponent("App/Package.swift"),
                root.appendingPathComponent("App/Sources/App/Main.swift"),
            ]],
            productRoots: scratch(root)
        )

        #expect(roots == [canonical(root, "App/Sources/App")])
    }

    @Test("SwiftPM evidence: dependency roots in, fetched and generated out")
    func spmEvidenceDerivation() throws {
        let root = try makeWorkspace()
        defer { try? FileManager.default.removeItem(at: root) }

        let evidence = try #require(SPMBuildSystem.deriveEvidence(
            manifestContents: manifestYAML(root: root),
            scratchDirectory: root.appendingPathComponent("App/.build"),
            projectRoot: root.appendingPathComponent("App")
        ))

        #expect(evidence.sourceDirectories == [
            canonical(root, "App/Sources/App"),
            canonical(root, "Dep/Sources/Dep"),
        ])
        #expect(evidence.runtimeInputs == [
            canonical(root, "App/Sources/App/Resources/value.txt"),
        ])
        #expect(evidence.definitionFiles.map(\.lastPathComponent).sorted() == [
            "Package.resolved", "Package.swift", "Package.swift",
        ])
    }

    @Test("Bazel source groups: one per SwiftCompile action")
    func bazelSourceGroups() {
        let jsonProto = """
        {"actions": [
          {"mnemonic": "SwiftCompile", "arguments": ["swiftc", "-module-name", "App", \
        "Sources/App/Main.swift", "Sources/App/Helper.swift"]},
          {"mnemonic": "SwiftCompile", "arguments": ["swiftc", "-module-name", "Badge", \
        "external/local_badge+/Sources/LocalBadge.swift"]},
          {"mnemonic": "CppCompile", "arguments": ["clang", "foo.cc"]}
        ]}
        """
        let groups = BazelCommandCapture.allSwiftSourceGroups(jsonProto: jsonProto)
        #expect(groups == [
            ["Sources/App/Main.swift", "Sources/App/Helper.swift"],
            ["external/local_badge+/Sources/LocalBadge.swift"],
        ])
    }

    private func manifestYAML(root: URL) -> String {
        let app = root.appendingPathComponent("App").path
        let dep = root.appendingPathComponent("Dep").path
        let appSources =
            "\"\(app)/Sources/App/Main.swift\",\"\(app)/Sources/App/Helper.swift\","
                + "\"\(app)/.build/plugins/outputs/generated/Gen.swift\","
                + "\"\(app)/.build/debug/Dep.swiftmodule\""
        return """
        commands:
          "C.App-debug.module":
            tool: swift-compiler
            inputs: [\(appSources)]
            args: ["swiftc","-module-name","App","-c"]
          "C.Dep-debug.module":
            tool: swift-compiler
            inputs: ["\(dep)/Sources/Dep/Shared.swift"]
            args: ["swiftc","-module-name","Dep","-c"]
          "C.Fetched-debug.module":
            tool: swift-compiler
            inputs: ["\(app)/.build/checkouts/Fetched/Sources/Fetched/F.swift"]
            args: ["swiftc","-module-name","Fetched","-c"]
          "\(app)/.build/debug/App_App.bundle/value.txt":
            tool: copy-tool
            inputs: ["\(app)/Sources/App/Resources/value.txt"]
            outputs: ["\(app)/.build/debug/App_App.bundle/value.txt"]
        """
    }
}

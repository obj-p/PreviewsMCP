import Foundation
import Testing

/// Automated guards for `examples/regress` matrix rows that flipped to
/// "Guard passes" (see `examples/regress/VERIFICATION.md`). One test per
/// row, asserting the row's healthy-result contract: render rows assert a
/// successful one-shot `snapshot` producing a valid PNG; error rows assert
/// the exact classified diagnostic. Detection rows run without `--project`
/// or `--build-system` overrides — auto-detection is what they guard.
///
/// This first tranche covers the rows that need no Xcode build, no
/// simulator, no artifact generation, and no network: the deterministic
/// macOS SwiftPM and error-contract rows. Rows staying manual-only for a
/// named flake reason: W03 (FSEvents timing, #298), L05 (concurrency),
/// S05/S06 (swift-syntax fetch), M01/M02 (launch assertions elsewhere).
@Suite("Regress guard rows", .serialized)
struct RegressGuardTests {
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    private static func fixture(_ relativePath: String) -> String {
        CLIRunner.regressRoot.appendingPathComponent(relativePath).path
    }

    /// Run a one-shot snapshot of `relativePath` with no detection overrides
    /// and assert it renders a valid PNG.
    private static func assertRenders(
        _ relativePath: String, extraArguments: [String] = []
    ) async throws {
        try await DaemonTestLock.run {
            try await cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [fixture(relativePath), "-o", outputPath] + extraArguments
            )
            #expect(result.exitCode == 0, "stderr: \(result.stderr)")
            try CLIRunner.assertValidPNG(at: outputPath)
        }
    }

    /// Run a one-shot snapshot of `relativePath` and assert it fails with
    /// every expected diagnostic substring in the combined output.
    private static func assertFails(
        _ relativePath: String, containing expected: [String]
    ) async throws {
        try await DaemonTestLock.run {
            try await cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let result = try await CLIRunner.run(
                "snapshot", arguments: [fixture(relativePath), "-o", outputPath]
            )
            #expect(result.exitCode != 0, "expected a classified failure, got success")
            let combined = result.stdout + result.stderr
            for substring in expected {
                #expect(
                    combined.contains(substring),
                    "diagnostic should contain '\(substring)'; got: \(combined)"
                )
            }
        }
    }

    // MARK: - Detection rows

    /// D02: a Swift package nested below a Bazel root is selected and renders.
    @Test("D02: nested package below a Bazel root", .timeLimit(.minutes(5)))
    func d02NestedPackageBelowBazelRoot() async throws {
        try await Self.assertRenders(
            "detection/mixed-marker-workspace/NestedPackage/Sources/NestedPackage/NestedPackagePreview.swift"
        )
    }

    /// D05: `Package.swift`, `MODULE.bazel`, and `BUILD.bazel` at one root
    /// resolve through the documented tie-break (SwiftPM first) and render.
    @Test("D05: same-directory marker tie-break", .timeLimit(.minutes(5)))
    func d05SameDirectoryMarkers() async throws {
        try await Self.assertRenders(
            "detection/same-directory-markers/Sources/HybridMarker/HybridMarkerPreview.swift"
        )
    }

    /// D06: an XcodeGen manifest with no generated project is diagnosed with
    /// the regeneration hint instead of a generic ownership failure.
    @Test("D06: missing generated project diagnosis", .timeLimit(.minutes(5)))
    func d06MissingGeneratedOutput() async throws {
        try await Self.assertFails(
            "generated-project-state/missing-output/Sources/MissingOutputPreview.swift",
            containing: ["xcodegen generate"]
        )
    }

    /// D07: a source file missing from a stale generated project is diagnosed
    /// with the owning project and the staleness hint.
    @Test("D07: stale generated project diagnosis", .timeLimit(.minutes(5)))
    func d07StaleGeneratedOutput() async throws {
        try await Self.assertFails(
            "generated-project-state/stale-output/Sources/NewPreview.swift",
            containing: [
                "no target in StaleOutput.xcodeproj compiles NewPreview.swift",
                "the project may be stale",
            ]
        )
    }

    // MARK: - SwiftPM compile-capture rows

    /// S01: language mode, conditional flags, C module, generated source,
    /// resources, and explicit membership compile through the captured command.
    @Test("S01: captured settings fixture renders", .timeLimit(.minutes(5)))
    func s01SettingsFixture() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/SettingsFixture/SettingsPreview.swift"
        )
    }

    /// S02: upcoming features, unsafe flags, and conditional defines forward
    /// through the normalized captured command.
    @Test("S02: compiler settings preserved", .timeLimit(.minutes(5)))
    func s02CompilerSettings() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/CompilerSettings/CompilerSettingsPreview.swift"
        )
    }

    /// S03: a build-tool plugin's generated Swift source is a captured
    /// compile input.
    @Test("S03: plugin-generated source compiles", .timeLimit(.minutes(5)))
    func s03GeneratedPlugin() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/GeneratedPlugin/GeneratedPluginPreview.swift"
        )
    }

    /// S04: explicit source exclusion is honored and the Clang module resolves.
    @Test("S04: membership exclusion and C module", .timeLimit(.minutes(5)))
    func s04MembershipAndC() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/MembershipAndC/MembershipAndCPreview.swift"
        )
    }

    // MARK: - Preview-form rows

    /// V01: a legacy `PreviewProvider` declaration renders.
    @Test("V01: legacy PreviewProvider renders", .timeLimit(.minutes(5)))
    func v01LegacyProvider() async throws {
        try await Self.assertRenders(
            "preview-forms/Sources/PreviewForms/LegacyProvider.swift"
        )
    }

    /// V03: duplicate display names keep stable index-based selection.
    @Test("V03: duplicate names select by index", .timeLimit(.minutes(5)))
    func v03DuplicateNames() async throws {
        try await Self.assertRenders(
            "preview-forms/Sources/PreviewForms/DuplicateNames.swift",
            extraArguments: ["--preview", "1"]
        )
    }

    /// V04: a preview in a constrained generic context compiles and renders.
    @Test("V04: constrained generic context renders", .timeLimit(.minutes(5)))
    func v04GenericContext() async throws {
        try await Self.assertRenders(
            "preview-forms/Sources/PreviewForms/GenericContext.swift"
        )
    }

    /// V05: a source with no preview declaration returns the specific
    /// zero-preview diagnostic.
    @Test("V05: zero-preview diagnostic", .timeLimit(.minutes(5)))
    func v05NoPreview() async throws {
        try await Self.assertFails(
            "preview-forms/Sources/PreviewForms/NoPreview.swift",
            containing: ["Preview index 0 not found. File has 0 preview(s)."]
        )
    }

    // MARK: - Setup-fault rows

    /// T02: a setup package that fails to compile returns a setup-specific
    /// build error while the daemon stays alive. The liveness check runs
    /// inside the same lock block: the writer-fence kills the daemon when
    /// the block ends, so a second block would always find it dead.
    @Test("T02: setup build failure is classified", .timeLimit(.minutes(5)))
    func t02SetupBuildFailure() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let outputPath = tempDir.appendingPathComponent("snapshot.png").path
            let result = try await CLIRunner.run(
                "snapshot",
                arguments: [
                    Self.fixture(
                        "setup-faults/build-failure/Sources/SetupFaultApp/SetupFaultPreview.swift"
                    ),
                    "-o", outputPath,
                ]
            )
            #expect(result.exitCode != 0, "expected a classified setup failure, got success")
            let combined = result.stdout + result.stderr
            #expect(
                combined.contains("Setup package 'BrokenPreviewSetup' build failed"),
                "diagnostic should name the setup package; got: \(combined)"
            )

            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should stay healthy after a setup failure")
            #expect(status.stdout.contains("daemon running"), "status: \(status.stdout)")
        }
    }
}

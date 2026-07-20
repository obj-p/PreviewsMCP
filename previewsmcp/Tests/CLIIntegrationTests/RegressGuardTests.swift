import AppKit
import Foundation
import Testing

/// Automated guards for `examples/regress` matrix rows that flipped to
/// "Guard passes" (see `examples/regress/VERIFICATION.md`). One test per
/// row, asserting the row's healthy-result contract: render rows assert a
/// successful one-shot `snapshot` producing a valid, non-blank PNG; error
/// rows assert the diagnostic tokens the contract guarantees (identifiers
/// and command names, not connective prose). Detection rows run without
/// `--project` or `--build-system` overrides — auto-detection is what
/// they guard. Rows whose regression would still render (D05's tie-break)
/// assert the daemon's ownership log line instead of pixels.
///
/// The first tranche covers the rows that need no Xcode build, no
/// simulator, no artifact generation, and no network: the deterministic
/// macOS SwiftPM and error-contract rows. The second tranche adds the
/// macOS Xcode rows (D01, D03, D08, X02), which build through
/// `xcodebuild` but still need no simulator, artifact generation, or
/// network — every fixture's generated project is committed. Rows
/// staying manual-only for a named flake reason: W03 (FSEvents timing,
/// #298), L05 (concurrency), S05/S06 (swift-syntax fetch), M01/M02
/// (launch assertions elsewhere). Future tranches that need simulators,
/// artifact generation, or network must land in a separate test target,
/// not this file — this target's glob feeds the required `ci` gate.
@Suite("Regress guard rows", .serialized)
struct RegressGuardTests {
    private static func cleanSlate() async throws {
        _ = try? await CLIRunner.run("kill-daemon", arguments: ["--timeout", "2"])
    }

    private static func fixture(_ relativePath: String) -> String {
        CLIRunner.regressRoot.appendingPathComponent(relativePath).path
    }

    /// Run a one-shot snapshot of `relativePath` with no detection overrides
    /// and assert it renders a valid, non-blank PNG. `thenWhileAlive` runs
    /// inside the same lock block, before the writer-fence kills the daemon,
    /// for assertions that need the daemon's state (logs, status).
    private static func assertRenders(
        _ relativePath: String,
        extraArguments: [String] = [],
        thenWhileAlive: @Sendable () async throws -> Void = {}
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
            try CLIRunner.assertNonBlankPNG(at: outputPath)
            try await thenWhileAlive()
        }
    }

    /// Run a one-shot snapshot of `relativePath` and assert it fails with
    /// every expected diagnostic token in the combined output. `thenWhileAlive`
    /// runs inside the same lock block, before the writer-fence kills the
    /// daemon.
    private static func assertFails(
        _ relativePath: String,
        containing expected: [String],
        thenWhileAlive: @Sendable () async throws -> Void = {}
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
            for token in expected {
                #expect(
                    combined.contains(token),
                    "diagnostic should contain '\(token)'; got: \(combined)"
                )
            }
            try await thenWhileAlive()
        }
    }

    /// Assert the daemon log records the ownership walk confirming `kind`
    /// for `fileName`. This is the observable for rows whose regression
    /// still renders (a wrong build system compiling the same source).
    private static func assertOwnershipLogged(kind: String, fileName: String) async throws {
        let logs = try await CLIRunner.run("logs", arguments: ["-n", "300"])
        #expect(logs.exitCode == 0, "logs stderr: \(logs.stderr)")
        #expect(
            logs.stdout.contains("ownership: \(kind) confirmed") && logs.stdout.contains(fileName),
            "daemon log should record '\(kind)' confirming \(fileName)"
        )
    }

    // MARK: - Detection rows

    /// D01: an Xcode project nested below a distant Bazel root is selected
    /// and renders; the walk confirms membership in the nearer project.
    /// Previously the distant root claimed the file and failed.
    @Test("D01: nested Xcode project below a Bazel root", .timeLimit(.minutes(5)))
    func d01NestedXcodeBelowBazelRoot() async throws {
        try await Self.assertRenders(
            "detection/mixed-marker-workspace/XcodeOnlyApp/Sources/MarkerPreview.swift"
        ) {
            try await Self.assertOwnershipLogged(kind: "xcode", fileName: "MarkerPreview.swift")
        }
    }

    /// D02: a Swift package nested below a Bazel root is selected and renders.
    @Test("D02: nested package below a Bazel root", .timeLimit(.minutes(5)))
    func d02NestedPackageBelowBazelRoot() async throws {
        try await Self.assertRenders(
            "detection/mixed-marker-workspace/NestedPackage/Sources/NestedPackage/NestedPackagePreview.swift"
        ) {
            try await Self.assertOwnershipLogged(kind: "spm", fileName: "NestedPackagePreview.swift")
        }
    }

    /// D03: an Xcode project below an outer `Package.swift` is selected —
    /// the outer package must not claim the file.
    @Test("D03: nested Xcode project below an outer package", .timeLimit(.minutes(5)))
    func d03NestedXcodeBelowOuterPackage() async throws {
        try await Self.assertRenders(
            "detection/outer-spm-workspace/NestedXcode/Sources/OuterBoundaryPreview.swift"
        ) {
            try await Self.assertOwnershipLogged(
                kind: "xcode", fileName: "OuterBoundaryPreview.swift"
            )
        }
    }

    /// D05: `Package.swift`, `MODULE.bazel`, and `BUILD.bazel` at one root
    /// resolve through the documented tie-break (SwiftPM first). All three
    /// systems compile this fixture to identical pixels, so the guard is the
    /// daemon's ownership log line, not the render.
    @Test("D05: same-directory marker tie-break", .timeLimit(.minutes(5)))
    func d05SameDirectoryMarkers() async throws {
        try await Self.assertRenders(
            "detection/same-directory-markers/Sources/HybridMarker/HybridMarkerPreview.swift"
        ) {
            try await Self.assertOwnershipLogged(kind: "spm", fileName: "HybridMarkerPreview.swift")
        }
    }

    /// D06: an XcodeGen manifest with no generated project is diagnosed with
    /// the missing-output-specific message and the regeneration hint.
    @Test("D06: missing generated project diagnosis", .timeLimit(.minutes(5)))
    func d06MissingGeneratedOutput() async throws {
        try await Self.assertFails(
            "generated-project-state/missing-output/Sources/MissingOutputPreview.swift",
            containing: ["no generated .xcodeproj", "xcodegen generate"]
        )
    }

    /// D07: a source file missing from a stale generated project is diagnosed
    /// with the owning project, the file, and the staleness hint. Tokens, not
    /// prose: the connective sentence may be reworded.
    @Test("D07: stale generated project diagnosis", .timeLimit(.minutes(5)))
    func d07StaleGeneratedOutput() async throws {
        try await Self.assertFails(
            "generated-project-state/stale-output/Sources/NewPreview.swift",
            containing: ["StaleOutput.xcodeproj", "NewPreview.swift", "stale"]
        )
    }

    /// D08: one scheme builds multiple targets; membership selects the
    /// target that owns the source. Previously the file compiled as the
    /// sibling module and failed.
    @Test("D08: multi-target scheme selects the owning target", .timeLimit(.minutes(5)))
    func d08MultiTargetOwnership() async throws {
        try await Self.assertRenders(
            "generated-project-state/multi-target/Sources/Beta/BetaPreview.swift"
        ) {
            try await Self.assertOwnershipLogged(kind: "xcode", fileName: "BetaPreview.swift")
        }
    }

    // MARK: - Xcode compile-capture rows

    /// X02: an Objective-C bridging header on an Xcode target forwards
    /// through the captured compile command (`-import-objc-header`) and
    /// the target's ObjC objects link into the JIT. A regression is a
    /// loud failure — `BridgedGreeting` is visible only through the
    /// header.
    @Test("X02: bridging header forwarded and ObjC linked", .timeLimit(.minutes(5)))
    func x02BridgingHeader() async throws {
        try await Self.assertRenders("xcode-bridging/Sources/BridgingPreview.swift")
    }

    // MARK: - SwiftPM compile-capture rows

    /// S01: language mode, conditional flags, C module, generated source,
    /// resources, and explicit membership compile through the captured
    /// command. The fixture fails closed: a dropped define is a compile
    /// error and an unstaged resource is a render crash, so exit 0 + a
    /// non-blank PNG covers the whole contract.
    @Test("S01: captured settings fixture renders", .timeLimit(.minutes(5)))
    func s01SettingsFixture() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/SettingsFixture/SettingsPreview.swift"
        )
    }

    /// S02: upcoming features, unsafe flags, and conditional defines forward
    /// through the normalized captured command. The fixture fails closed on
    /// a dropped define (#error).
    @Test("S02: compiler settings preserved", .timeLimit(.minutes(5)))
    func s02CompilerSettings() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/CompilerSettings/CompilerSettingsPreview.swift"
        )
    }

    /// S03: a build-tool plugin's generated Swift source is a captured
    /// compile input (a miss is a compile error).
    @Test("S03: plugin-generated source compiles", .timeLimit(.minutes(5)))
    func s03GeneratedPlugin() async throws {
        try await Self.assertRenders(
            "spm-settings/Sources/GeneratedPlugin/GeneratedPluginPreview.swift"
        )
    }

    /// S04: explicit source exclusion is honored and the Clang module
    /// resolves (a miss is a compile error).
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
    /// Renders index 0 and index 1 and asserts the images differ — the two
    /// declarations render distinguishable content, so identical bytes mean
    /// index selection collapsed.
    @Test("V03: duplicate names select by index", .timeLimit(.minutes(5)))
    func v03DuplicateNames() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }

            let file = Self.fixture("preview-forms/Sources/PreviewForms/DuplicateNames.swift")
            let output0 = tempDir.appendingPathComponent("index0.png").path
            let output1 = tempDir.appendingPathComponent("index1.png").path

            let result0 = try await CLIRunner.run("snapshot", arguments: [file, "-o", output0])
            #expect(result0.exitCode == 0, "index 0 stderr: \(result0.stderr)")
            let result1 = try await CLIRunner.run(
                "snapshot", arguments: [file, "-o", output1, "--preview", "1"]
            )
            #expect(result1.exitCode == 0, "index 1 stderr: \(result1.stderr)")

            try CLIRunner.assertValidPNG(at: output0)
            try CLIRunner.assertValidPNG(at: output1)
            let data0 = try Data(contentsOf: URL(fileURLWithPath: output0))
            let data1 = try Data(contentsOf: URL(fileURLWithPath: output1))
            #expect(
                data0 != data1,
                "index 0 and index 1 should render distinct declarations"
            )
        }
    }

    /// V04: a preview in a constrained generic context compiles and renders.
    @Test("V04: constrained generic context renders", .timeLimit(.minutes(5)))
    func v04GenericContext() async throws {
        try await Self.assertRenders(
            "preview-forms/Sources/PreviewForms/GenericContext.swift"
        )
    }

    /// V05: a source with no preview declaration returns the specific
    /// zero-preview diagnostic (a deliberate UX string, pinned verbatim).
    @Test("V05: zero-preview diagnostic", .timeLimit(.minutes(5)))
    func v05NoPreview() async throws {
        try await Self.assertFails(
            "preview-forms/Sources/PreviewForms/NoPreview.swift",
            containing: ["Preview index 0 not found. File has 0 preview(s)."]
        )
    }

    // MARK: - Config-discovery rows

    /// C03/C04/C05: config discovery is walked fresh per session start in
    /// one daemon — a nearer config appearing, an in-place edit, and a
    /// removal are each visible to the next start. The whole sequence runs
    /// in one lock block because the same-daemon semantics are the
    /// contract; the rendered scheme is read from the snapshot's
    /// background luminance.
    @Test("C03/C04/C05: config discovery fresh per start", .timeLimit(.minutes(5)))
    func configRowsFreshPerStart() async throws {
        try await DaemonTestLock.run {
            try await Self.cleanSlate()
            let tempDir = try CLIRunner.makeTempDir()
            defer { try? FileManager.default.removeItem(at: tempDir) }
            let nearer = URL(fileURLWithPath: Self.fixture("config-cache/Nested/.previewsmcp.json"))
            try? FileManager.default.removeItem(at: nearer)
            defer { try? FileManager.default.removeItem(at: nearer) }
            let source = Self.fixture(
                "config-cache/Nested/Sources/ConfigCache/ConfigCachePreview.swift"
            )

            @Sendable func rendersDark(_ name: String) async throws -> Bool {
                let out = tempDir.appendingPathComponent(name).path
                let result = try await CLIRunner.run("snapshot", arguments: [source, "-o", out])
                #expect(result.exitCode == 0, "\(name) stderr: \(result.stderr)")
                let rep = try #require(
                    NSBitmapImageRep(data: Data(contentsOf: URL(fileURLWithPath: out)))
                )
                let bytes = try #require(rep.bitmapData)
                return bytes[0] < 128
            }

            #expect(try await rendersDark("base.png") == false, "parent light config applies")

            try #"{"traits": {"colorScheme": "dark"}}"#
                .write(to: nearer, atomically: true, encoding: .utf8)
            #expect(try await rendersDark("c03.png") == true, "C03: nearer config appeared")

            try #"{"traits": {"colorScheme": "light"}}"#
                .write(to: nearer, atomically: true, encoding: .utf8)
            #expect(try await rendersDark("c04.png") == false, "C04: in-place edit re-read")

            try #"{"traits": {"colorScheme": "dark"}}"#
                .write(to: nearer, atomically: true, encoding: .utf8)
            #expect(try await rendersDark("c05-pre.png") == true, "C05 precondition: dark applies")

            try FileManager.default.removeItem(at: nearer)
            #expect(try await rendersDark("c05.png") == false, "C05: removal falls back to parent")
        }
    }

    // MARK: - Setup-fault rows

    /// T02: a setup package that fails to compile returns a setup-specific
    /// build error while the daemon stays alive. The liveness check runs
    /// inside the same lock block: the writer-fence kills the daemon when
    /// the block ends.
    @Test("T02: setup build failure is classified", .timeLimit(.minutes(5)))
    func t02SetupBuildFailure() async throws {
        try await Self.assertFails(
            "setup-faults/build-failure/Sources/SetupFaultApp/SetupFaultPreview.swift",
            containing: ["Setup package 'BrokenPreviewSetup' build failed"]
        ) {
            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should stay healthy after a setup failure")
            #expect(status.stdout.contains("daemon running"), "status: \(status.stdout)")
        }
    }
}

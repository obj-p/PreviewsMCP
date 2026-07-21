import AppKit
import Foundation
import PreviewsTestSupport
import Testing

/// Automated guards for `examples/regress` matrix rows that need build
/// tooling the deterministic `RegressGuardTests` target must not depend
/// on: fixture artifact generation (`binary-frameworks/
/// generate-artifacts.sh`, `large-tier2/generate-sources.sh`), a Bazel
/// fetch of the fixture's pinned rules (B01), or an iOS simulator. Row
/// conventions match `RegressGuardTests`: one test per row, the row's
/// healthy-result contract, no detection overrides, presence-only tick
/// regexes, `.minutes(10)` time limits (the DaemonTestLock rule).
///
/// This target is tagged `manual`, so neither required-gate tier's
/// `bazel test //...` expansion runs it; the non-required `regress-tools`
/// job in `.github/workflows/ci.yml` names it explicitly for signal.
/// Tool preconditions skip locally but FAIL when
/// `RequiredGateEnforcement.enforced` is set (the required-gate coverage
/// signal ci.yml exports), so the CI job can never silently skip a row.
@Suite("Regress tool-guard rows", .serialized)
struct RegressToolGuardTests {
    /// Run one of the fixture generator scripts, exactly as the manual
    /// matrix pass does (`VERIFICATION.md` repeatability notes). The
    /// scripts regenerate from scratch, so a stale artifact can never
    /// satisfy a guard.
    private static func generate(
        _ scriptRelativePath: String, environment: [String] = []
    ) async throws {
        let result = try await CLIRunner.runExternal(
            "/usr/bin/env",
            arguments: environment
                + ["/bin/bash", RegressRowAsserts.fixture(scriptRelativePath)]
        )
        try #require(
            result.exitCode == 0,
            "\(scriptRelativePath) failed: \(result.stdout)\n\(result.stderr)"
        )
    }

    /// One fresh XCFramework generation per test process, shared by the
    /// three binary-framework rows (B02/B03/F01) — the script rebuilds
    /// every artifact from scratch, so a second run in the same process
    /// buys nothing but ~15s of xcodebuild on the serial runner. The Task
    /// runs `generate` lazily on first await and caches its outcome
    /// (including a failure) for the rest.
    private static let binaryFrameworkArtifacts = Task {
        try await generate("binary-frameworks/generate-artifacts.sh")
    }

    /// Skip (locally) or fail (on the gate) when `tool` is not reachable
    /// on this target's pinned PATH. Returns false to skip.
    private static func requireTool(_ tool: String) async throws -> Bool {
        if await CLIRunner.toolAvailable(tool) { return true }
        try #require(
            !RequiredGateEnforcement.enforced,
            "\(tool) is required on the regress-tools gate but is not available"
        )
        print("\(tool) not available — skipping")
        return false
    }

    // MARK: - Artifact-generation rows

    /// P01: a cold build of a 2,000-file target ticks an elapsed-time
    /// heartbeat on the build phase (phase/error stage 2). The fixture's
    /// SwiftPM products are cleaned first — the row's contract is the
    /// previously silent COLD interval. Presence-only tick regex.
    @Test("P01: cold large-target build heartbeats", .timeLimit(.minutes(10)))
    func p01ColdBuildHeartbeat() async throws {
        try await Self.generate(
            "large-tier2/generate-sources.sh", environment: ["FILE_COUNT=2000"]
        )
        try? FileManager.default.removeItem(
            at: CLIRunner.regressRoot.appendingPathComponent("large-tier2/.build")
        )
        let result = try await RegressRowAsserts.assertRenders(
            "large-tier2/Sources/LargeTier2/LargeTier2Preview.swift"
        )
        #expect(
            result.stderr.range(
                of: #"Building \(SPMBuildSystem\)\.\.\. \(\d+s\)"#, options: .regularExpression
            ) != nil,
            "build phase should tick an elapsed heartbeat: \(result.stderr)"
        )
    }

    // MARK: - iOS simulator support

    /// Provision the dedicated device for this target, holding
    /// `SimulatorTestLock` as `SimulatorTestDevices.udid` requires, and
    /// reset host CoreSimulator state once before the first boot.
    /// Returns nil to skip locally; on the gate a missing device throws
    /// (`requiresDedicatedSim`).
    private static func provisionSimulator() async throws
        -> (udid: String, lock: SimulatorTestLock.Guard)?
    {
        let simLock = try await SimulatorTestLock.acquire()
        guard let udid = try await SimulatorTestDevices.udid(index: 9) else {
            print("Host cannot create \(SimulatorTestDevices.name(index: 9)) — skipping")
            simLock.release()
            return nil
        }
        await CoreSimulatorHygiene.resetOnce()
        return (udid, simLock)
    }

    // MARK: - Binary-framework rows (iOS)

    /// B02: the combined static + dynamic XCFramework package renders on
    /// the iOS simulator — the captured flags resolve the static module
    /// and its copied archive links alongside the dynamic framework.
    @Test("B02: combined XCFrameworks render on iOS", .timeLimit(.minutes(10)))
    func b02CombinedXCFrameworks() async throws {
        guard let sim = try await Self.provisionSimulator() else { return }
        defer { sim.lock.release() }
        try await Self.binaryFrameworkArtifacts.value
        try await RegressRowAsserts.assertRenders(
            "binary-frameworks/combined/Sources/CombinedBinaryFixture/BinaryFrameworkPreview.swift",
            extraArguments: ["--platform", "ios", "--device", sim.udid]
        )
    }

    /// B03: the static-only XCFramework package renders on the iOS
    /// simulator — the module resolves from the captured flags and the
    /// copied `libStaticBadge.a` links from binPath.
    @Test("B03: static XCFramework renders on iOS", .timeLimit(.minutes(10)))
    func b03StaticXCFramework() async throws {
        guard let sim = try await Self.provisionSimulator() else { return }
        defer { sim.lock.release() }
        try await Self.binaryFrameworkArtifacts.value
        try await RegressRowAsserts.assertRenders(
            "binary-frameworks/static-only/Sources/StaticBinaryFixture/StaticBinaryPreview.swift",
            extraArguments: ["--platform", "ios", "--device", sim.udid]
        )
    }

    /// F01: an XCFramework with no iOS simulator slice fails the iOS
    /// start with the classified slice error naming the available
    /// identifiers (phase/error stage 4); the daemon stays responsive.
    @Test("F01: missing simulator slice is classified", .timeLimit(.minutes(10)))
    func f01BadSliceClassified() async throws {
        guard let sim = try await Self.provisionSimulator() else { return }
        defer { sim.lock.release() }
        try await Self.binaryFrameworkArtifacts.value
        try await RegressRowAsserts.assertFails(
            "binary-frameworks/bad-slice/Sources/BadSliceFixture/BadSlicePreview.swift",
            extraArguments: ["--platform", "ios", "--device", sim.udid],
            containing: ["has no iOS simulator slice", "ios-arm64"]
        ) {
            let status = try await CLIRunner.run("status")
            #expect(status.exitCode == 0, "daemon should survive the classified slice error")
            #expect(status.stdout.contains("daemon running"), "status: \(status.stdout)")
        }
    }

    // MARK: - Lifecycle row (iOS)

    /// L04: an out-of-band agent death (deterministic trigger:
    /// `simctl terminate` on the agent bundle) is logged as a crash and
    /// respawned; the next command succeeds and carries the crash notice,
    /// and the notice clears on delivery.
    @Test("L04: agent kill respawns with a crash notice", .timeLimit(.minutes(10)))
    func l04AgentKillRespawns() async throws {
        guard let sim = try await Self.provisionSimulator() else { return }
        defer { sim.lock.release() }
        try await DaemonTestLock.run {
            try await RegressRowAsserts.cleanSlate()
            let runResult = try await CLIRunner.run(
                "run",
                arguments: [
                    RegressRowAsserts.fixture("lifecycle-faults/Sources/AgentCrash/AgentCrashPreview.swift"),
                    "--platform", "ios", "--device", sim.udid, "--detach", "--headless",
                ]
            )
            #expect(runResult.exitCode == 0, "detach stderr: \(runResult.stderr)")

            let terminate = try await CLIRunner.runExternal(
                "/usr/bin/xcrun",
                arguments: ["simctl", "terminate", sim.udid, "com.previewsmcp.agent"]
            )
            try #require(terminate.exitCode == 0, "terminate stderr: \(terminate.stderr)")

            let clock = SuspendingClock()
            var deadline = clock.now.advanced(by: .seconds(60))
            var respawnLogged = false
            while clock.now < deadline {
                let logs = try await CLIRunner.run("logs", arguments: ["-n", "200"])
                if logs.stdout.contains("agent died out of band (crash #1); respawning") {
                    respawnLogged = true
                    break
                }
                try await clock.sleep(for: .milliseconds(500))
            }
            #expect(respawnLogged, "daemon should log the out-of-band death and respawn")

            // The respawn log line marks relaunch START; commands issued
            // mid-relaunch fail before a response is assembled, which
            // leaves the crash notice unconsumed. Retry until the respawned
            // agent serves a response — that first success must carry the
            // notice.
            deadline = clock.now.advanced(by: .seconds(120))
            var elements = try await CLIRunner.run("elements")
            while elements.exitCode != 0, clock.now < deadline {
                try await clock.sleep(for: .seconds(2))
                elements = try await CLIRunner.run("elements")
            }
            #expect(elements.exitCode == 0, "post-crash elements stderr: \(elements.stderr)")
            let combined = elements.stdout + elements.stderr
            #expect(
                combined.contains("The preview agent crashed and was relaunched"),
                "first post-crash response should carry the crash notice: \(combined)"
            )
            #expect(
                combined.contains("crash #1"),
                "notice should count the crash: \(combined)"
            )

            let followUp = try await CLIRunner.run("elements")
            #expect(followUp.exitCode == 0, "follow-up stderr: \(followUp.stderr)")
            #expect(
                !(followUp.stdout + followUp.stderr)
                    .contains("The preview agent crashed and was relaunched"),
                "crash notice must clear on delivery: \(followUp.stdout)"
            )

            let stop = try await CLIRunner.run("stop")
            #expect(stop.exitCode == 0, "stop stderr: \(stop.stderr)")
        }
    }

    // MARK: - Bazel row

    /// B01: the Bzlmod fixture renders through the aquery capture — the
    /// genrule source resolves at its execroot path and the canonical
    /// external repo's search path works. A capture regression fails the
    /// fixture build, so exit code + ownership log are the observables.
    @Test("B01: bzlmod fixture renders via aquery capture", .timeLimit(.minutes(10)))
    func b01BazelBzlmod() async throws {
        guard try await Self.requireTool("bazel") else { return }
        try await RegressRowAsserts.assertRenders("bazel-bzlmod/Sources/BzlmodPreview.swift") {
            let logs = try await CLIRunner.run("logs", arguments: ["-n", "300"])
            #expect(logs.exitCode == 0, "logs stderr: \(logs.stderr)")
            let confirmed = logs.stdout.split(separator: "\n").contains {
                $0.contains("ownership: bazel confirmed") && $0.contains("BzlmodPreview.swift")
            }
            #expect(confirmed, "daemon log should record bazel confirming BzlmodPreview.swift")
        }
    }
}

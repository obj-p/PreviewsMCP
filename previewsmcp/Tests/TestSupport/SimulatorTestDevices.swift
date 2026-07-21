import Foundation
import PreviewsCore

/// The required-gate enforcement policy: when the gate's coverage signal
/// is set, a missing test precondition (a dedicated simulator, a required
/// tool) must FAIL the run, never skip — a skip on the gate is a silent
/// coverage loss. Unset locally, so a dev host without the precondition
/// skips instead of blocking. Backed by the same three coupled sites
/// documented on `SimulatorTestDevices.requiresDedicatedSim`, which
/// delegates here; non-simulator preconditions (e.g.
/// `RegressToolGuardTests.requireTool`) read this general name directly.
public enum RequiredGateEnforcement {
    public static var enforced: Bool {
        ProcessInfo.processInfo.environment["PREVIEWSMCP_REQUIRE_DEDICATED_SIM"] != nil
    }
}

/// Dedicated, harness-owned simulators for the sim-booting test suites (#337).
///
/// The retired `IOSSimulatorPicker` copies assigned each test the index-th
/// available iPhone from the shared `simctl` pool, so which model an index
/// resolved to was arbitrary per machine and reshuffled when an Xcode update
/// changed the default device set.
///
/// Instead, each index resolves to a device NAMED `previewsmcp-test-<index>`,
/// created on demand as a pinned model (iPhone 17) on the newest installed
/// iOS 26+ runtime. The harness owns any device carrying that name: one with
/// the wrong device type, an unavailable runtime, or a duplicate name is
/// deleted and recreated. User-created devices are never touched.
///
/// `index` must be unique per test function that needs an isolated simulator —
/// duplicated indices would re-introduce the same-device contention the old
/// picker existed to eliminate. Declarative by design so reviewers notice
/// duplicates. Current assignments (grep `SimulatorTestDevices.udid(index:`):
///
/// - index 0: `SimulatorManagerTests.bootAndShutdown` (PreviewsIOSTests target)
/// - index 1: `IOSMCPTests.fullIOSWorkflow` (MCPIntegrationTests target);
///   shared with `SimulatorManagerTests.makeFramebufferStreamer`
///   (PreviewsIOSTests target — different targets never run concurrently)
/// - index 2: `IOSHIDInputTests.tapAndDrag` (MCPIntegrationTests target)
/// - index 3: `IOSAppServerTests.appServerEndToEnd` (MCPIntegrationTests target)
/// - index 4: `SimulatorManagerTests.makeHIDClient` (PreviewsIOSTests target)
/// - index 5: `SimulatorTestDevicesTests` (TestSupportTests target; resolves
///   only, never boots)
/// - index 6: `IOSPreviewE2ESupport.bootSimulator()` (IOSPreviewE2ETests
///   target; one warm-reused device for the whole `.serialized` suite)
/// - index 7: `IOSPreviewE2ETests` reclaim tests
///   (`stopShutsDownADeviceTheSessionBooted`,
///   `failedStartShutsDownADeviceTheSessionBooted`) — dedicated so pre-shutting
///   + fresh-booting it doesn't churn the index-6 warm-reused device (#391)
/// - index 8: `IOSCLIWorkflowTests.iosCLIWorkflow` (CLIIntegrationTests target;
///   pins the CLI run + variants sessions so the auto-select can't boot a
///   generic default device that nulls the agent CGSession, #391)
/// - index 9: `RegressToolGuardTests.provisionSimulator()` (RegressToolGuardTests
///   target; one device shared by its `.serialized` iOS rows B02/B03/F01/L04)
public enum SimulatorTestDevices {
    public static let deviceType = "com.apple.CoreSimulator.SimDeviceType.iPhone-17"

    /// Live previews need iOS 26+ (#282); pre-26 devices are never kept and
    /// never created.
    static let minimumIOSMajor = 26

    public static func name(index: Int) -> String {
        "previewsmcp-test-\(index)"
    }

    /// True when a dedicated simulator is REQUIRED (the merge-queue gate),
    /// so a `nil` from `udid` must FAIL rather than silently skip iOS coverage
    /// (the ~27s no-op false-green). False locally, so a dev without the pinned
    /// device set isn't blocked.
    ///
    /// Bazel SCRUBS the test-action env, so raw `GITHUB_ACTIONS`/`CI` never
    /// reach the sandbox — this reads a DEDICATED, purpose-specific var that
    /// three coupled sites keep alive; changing one without the others makes
    /// the guard inert:
    ///   1. this read of `PREVIEWSMCP_REQUIRE_DEDICATED_SIM`;
    ///   2. `.bazelrc` `test --test_env=PREVIEWSMCP_REQUIRE_DEDICATED_SIM`
    ///      (propagates it into the scrubbed sandbox when set — inert locally);
    ///   3. `.github/workflows/ci.yml` sets it =1 at job env + an "Assert
    ///      iOS-coverage signal" step that fails the gate if it's ever dropped.
    public static var requiresDedicatedSim: Bool {
        RequiredGateEnforcement.enforced
    }

    /// Apply the fail-vs-skip policy to a resolved device. This seam keeps the
    /// policy unit-testable without mutating the process environment.
    public static func enforceAvailability(
        _ udid: String?, index: Int, requiresDedicatedSim: Bool
    ) throws -> String? {
        guard udid == nil else { return udid }
        guard requiresDedicatedSim else { return nil }
        throw RequiredDeviceUnavailable(index: index)
    }

    /// Resolve the dedicated device for `index`, creating it if missing.
    ///
    /// Callers must hold `SimulatorTestLock`: create/delete mutate the shared
    /// CoreSimulator device set, and the lock is what makes the
    /// check-then-create idempotent across concurrent workspaces.
    ///
    /// Returns nil locally when the device cannot be provided. On the required
    /// gate, throws instead so callers cannot silently skip iOS coverage.
    public static func udid(index: Int) async throws -> String? {
        try enforceAvailability(
            await resolveUDID(index: index),
            index: index,
            requiresDedicatedSim: requiresDedicatedSim
        )
    }

    private static func resolveUDID(index: Int) async -> String? {
        let name = name(index: index)
        do {
            guard let devices = try await list(name: name) else { return nil }
            var keep: String?
            for device in devices {
                if keep == nil, device.isAvailable, device.deviceTypeIdentifier == deviceType,
                   device.iosMajor >= minimumIOSMajor
                {
                    keep = device.udid
                } else {
                    _ = try? await simctl(["delete", device.udid])
                }
            }
            if let keep { return keep }

            for runtime in try await supportedRuntimes() {
                let created = try await simctl(["create", name, deviceType, runtime])
                guard created.exitCode == 0 else { continue }
                let udid = created.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
                if !udid.isEmpty { return udid }
            }
            return nil
        } catch {
            print("SimulatorTestDevices: resolving \(name) failed: \(error)")
            return nil
        }
    }

    private struct RequiredDeviceUnavailable: LocalizedError {
        let index: Int

        var errorDescription: String? {
            "Required gate could not provision dedicated simulator index \(index) — "
                + "failing, not skipping (must not silently drop iOS coverage)."
        }
    }

    /// Installed iOS `minimumIOSMajor`+ runtime identifiers, newest first.
    /// Passed explicitly to `simctl create` so the runtime half of the device
    /// shape is pinned by the same rule the keep filter enforces, instead of
    /// by simctl's implicit default; creation walks the list so a runtime
    /// that rejects the pinned device type falls back to the next.
    private static func supportedRuntimes() async throws -> [String] {
        guard let runtimes = try await simctlJSON(["list", "runtimes"])?["runtimes"]
            as? [[String: Any]]
        else { return [] }

        return
            runtimes
                .filter { $0["isAvailable"] as? Bool == true }
                .compactMap { $0["identifier"] as? String }
                .filter { (versionComponents($0).first ?? 0) >= minimumIOSMajor }
                .sorted { versionComponents($1).lexicographicallyPrecedes(versionComponents($0)) }
    }

    /// Numeric version components of a runtime identifier like
    /// `com.apple.CoreSimulator.SimRuntime.iOS-26-2` → `[26, 2]`.
    private static func versionComponents(_ key: String) -> [Int] {
        guard let range = key.range(of: "SimRuntime.iOS-") else { return [] }
        return key[range.upperBound...].split(separator: "-").compactMap { Int($0) }
    }

    private struct Device {
        let udid: String
        let isAvailable: Bool
        let deviceTypeIdentifier: String
        let iosMajor: Int
    }

    /// Every device (available or not) named `name`, sorted by UDID. Includes
    /// unavailable ones so a stale device from a removed runtime is seen and
    /// recreated rather than shadowing the name forever. Nil when the listing
    /// itself failed — distinct from "no such device", so a listing hiccup
    /// never triggers a duplicate create.
    private static func list(name: String) async throws -> [Device]? {
        guard let devicesByRuntime = try await simctlJSON(["list", "devices"])?["devices"]
            as? [String: [[String: Any]]]
        else { return nil }

        var devices: [Device] = []
        for (runtime, list) in devicesByRuntime {
            for entry in list where entry["name"] as? String == name {
                guard let udid = entry["udid"] as? String else { continue }
                devices.append(
                    Device(
                        udid: udid,
                        isAvailable: entry["isAvailable"] as? Bool ?? false,
                        deviceTypeIdentifier: entry["deviceTypeIdentifier"] as? String ?? "",
                        iosMajor: versionComponents(runtime).first ?? 0
                    )
                )
            }
        }
        return devices.sorted { $0.udid < $1.udid }
    }

    /// Run a `--json` simctl listing and decode its top-level dictionary,
    /// or nil when the invocation or decode failed.
    private static func simctlJSON(_ arguments: [String]) async throws -> [String: Any]? {
        let output = try await simctl(arguments + ["--json"])
        guard output.exitCode == 0,
              let data = output.stdout.data(using: .utf8)
        else { return nil }
        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    /// A 60s timeout bounds a truly hung simctl (observed on PR #141 CI);
    /// normal invocations complete in <5s.
    private static func simctl(_ arguments: [String]) async throws -> ProcessOutput {
        try await runAsync(
            "/usr/bin/xcrun",
            arguments: ["simctl"] + arguments,
            discardStderr: true,
            timeout: .seconds(60)
        )
    }
}

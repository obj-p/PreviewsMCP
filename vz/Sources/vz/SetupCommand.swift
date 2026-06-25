import AppKit
import ArgumentParser
import Darwin
import Foundation
import VZKit

/// Phase 11c: drive Setup Assistant via a scripted keystroke sequence.
///
/// Today this command runs an **exploratory** sequence that screenshots
/// each SA screen in turn. The output directory ends up with a numbered
/// PNG sequence that lets us nail down the wait-and-tab script
/// empirically; once we've confirmed each screen and the keys that
/// advance it, we replace the exploration with the real script and the
/// command becomes the end-to-end "boot + Setup Assistant + ready for
/// SSH provisioning (#12)" driver.
struct SetupCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "setup",
        abstract: "Run Setup Assistant via scripted keystrokes (phase 11c — exploratory)."
    )

    @OptionGroup var bundle: BundleArgument

    @Option(name: .long, help: "Directory to write per-step screenshots to.")
    var outputDir: String = "/tmp/vz-setup"

    @Flag(
        name: .customLong("invisible"),
        help: "Use the off-screen window (production default). Default is visible at (80,80) so you can watch the run."
    )
    var invisible: Bool = false

    @Option(
        name: .customLong("preset"),
        help: "Which setup preset to run."
    )
    var preset: Preset = .provisionSSH

    @Option(
        name: .customLong("transport"),
        help: "Input transport. nsevent = NSApp.postEvent (fragile, public). vnc = _VZVNCServer SPI + in-process RFB client (production)."
    )
    var transport: Transport = .nsevent

    @Option(
        name: .customLong("retry"),
        help: "How many times to retry the full sequence on failure. Each retry restores --restore-from before booting."
    )
    var retry: Int = 0

    @Option(
        name: .customLong("restore-from"),
        help: "Snapshot to restore before each attempt. Required for retry > 0."
    )
    var restoreFrom: String?

    @Option(
        name: .customLong("plan"),
        help: "Path to a JSON screen-dispatch plan. When set, drives Setup Assistant via the plan's screen rules instead of a built-in preset. Requires --transport vnc."
    )
    var plan: String?

    @Flag(
        name: .customLong("recovery"),
        help: "Boot into macOS recoveryOS via VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery=true. Required by the recoveryOS-bound presets (explore-recovery, disable-sip)."
    )
    var recovery: Bool = false

    enum Preset: String, ExpressibleByArgument, CaseIterable {
        /// Restore from a `post-sa` snapshot, log in as admin, clear the
        /// per-user first-login Setup Assistant screens, open Terminal via
        /// Spotlight, install the bundle's SSH public key, then
        /// `shutdown -h now`. After this runs, `vz ssh <bundle> -- uname -a`
        /// succeeds and no further OCR is needed downstream.
        case provisionSSH = "provision-ssh"
    }

    enum Transport: String, ExpressibleByArgument, CaseIterable {
        case nsevent
        case vnc
    }

    func run() async throws {
        let bundle = try bundle.load()
        let outDir = URL(filePath: (outputDir as NSString).expandingTildeInPath)
        if FileManager.default.fileExists(atPath: outDir.path) {
            try? FileManager.default.removeItem(at: outDir)
        }
        try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        if transport != .vnc {
            throw VMError("--preset provision-ssh requires --transport vnc (needs OCR + modifier keys)")
        }
        let pubkey: String
        do {
            pubkey = try String(contentsOf: bundle.sshPublicKeyURL, encoding: .utf8)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch {
            throw VMError("could not read public key at \(bundle.sshPublicKeyURL.path)", underlying: error)
        }
        guard !pubkey.isEmpty else {
            throw VMError("public key at \(bundle.sshPublicKeyURL.path) is empty")
        }
        let steps = Self.provisionSSHSteps(pubkey: pubkey)

        if retry > 0, restoreFrom == nil {
            throw VMError("--retry > 0 requires --restore-from <snapshot-name>")
        }

        let dispatchRules: [ScreenRule]?
        let dispatchMaxIterations: Int
        if let planPath = plan {
            if transport != .vnc {
                throw VMError("--plan requires --transport vnc")
            }
            let loaded = try SetupPlan.load(
                from: URL(fileURLWithPath: (planPath as NSString).expandingTildeInPath)
            )
            dispatchRules = try loaded.screenRules()
            dispatchMaxIterations = loaded.maxIterations ?? 60
        } else {
            dispatchRules = nil
            dispatchMaxIterations = 60
        }

        let maxAttempts = retry + 1
        var lastError: Error?
        for attempt in 1 ... maxAttempts {
            // Restore between attempts (and on attempt 1 too, if requested).
            if let snapshot = restoreFrom {
                Log.info("attempt \(attempt)/\(maxAttempts): restoring '\(snapshot)' before run")
                try SnapshotStore.restore(name: snapshot, in: bundle)
            }

            // Per-attempt screenshot subdir so failed attempts aren't
            // overwritten by the eventual successful one.
            let attemptDir = maxAttempts > 1
                ? outDir.appending(path: "attempt-\(attempt)")
                : outDir
            try FileManager.default.createDirectory(
                at: attemptDir, withIntermediateDirectories: true
            )

            do {
                try await runOneAttempt(
                    bundle: bundle, steps: steps, dispatchRules: dispatchRules,
                    dispatchMaxIterations: dispatchMaxIterations, screenshotDir: attemptDir
                )
                Log.info("sequence succeeded on attempt \(attempt)")
                print(attemptDir.path)
                return
            } catch {
                lastError = error
                Log.info("attempt \(attempt) failed: \(error.localizedDescription)")
                if attempt < maxAttempts {
                    Log.info("retrying…")
                }
            }
        }
        throw lastError ?? VMError("sequence failed after \(maxAttempts) attempts")
    }

    private func runOneAttempt(
        bundle: VMBundle,
        steps: [SetupAssistantSequence.Step],
        dispatchRules: [ScreenRule]?,
        dispatchMaxIterations: Int,
        screenshotDir: URL
    ) async throws {
        let host = try await MainActor.run {
            try FirstBootHost(bundle: bundle, debugVisible: !invisible)
        }
        try await host.start(recovery: recovery)

        do {
            switch transport {
            case .nsevent:
                try await SetupAssistantSequence.run(
                    steps, host: host, screenshotDir: screenshotDir
                )
            case .vnc:
                let vnc = try await MainActor.run {
                    try VNCSPI.start(virtualMachine: host.machine, port: 0)
                }
                defer { Task { @MainActor in vnc.stop() } }

                let client = RFBClient()
                try client.connect(to: .init(host: "127.0.0.1", port: vnc.port), timeout: 10)
                try client.handshake()
                Log.info("RFB client ready; running sequence via VNC transport")

                if let dispatchRules {
                    try await SetupAssistantSequence.runDispatchVNC(
                        rules: dispatchRules, host: host, client: client,
                        screenshotDir: screenshotDir,
                        maxIterations: dispatchMaxIterations
                    )
                } else {
                    try await SetupAssistantSequence.runVNC(
                        steps, host: host, client: client, screenshotDir: screenshotDir
                    )
                }
            }
        } catch {
            Log.info("sequence threw: \(error.localizedDescription); force-stopping VM")
            try? await host.forceStop()
            await MainActor.run { host.close() }
            throw error
        }

        // provision-ssh ends with a graceful halt so persistent state
        // (authorized_keys, NVRAM) flushes before the disk image is
        // captured. Wait for the guest to reach `.stopped` on its own;
        // fall back to force-stop if it doesn't.
        do {
            Log.info("sequence complete; waiting up to 30s for graceful guest shutdown")
            try await host.waitForStop(timeout: 30)
            Log.info("guest stopped gracefully")
        } catch {
            Log.info("graceful shutdown did not complete: \(error.localizedDescription); force-stopping")
            try? await host.forceStop()
        }
        await MainActor.run { host.close() }
    }

    /// SSH provisioning sequence. Assumes the bundle has been restored
    /// from a `post-sa` snapshot, so the VM boots straight to the macOS
    /// lock screen with the admin user's password field focused.
    ///
    /// **Persistence model:** the in-session `launchctl enable +
    /// bootstrap` of ssh.plist works for the current boot, but on
    /// Tahoe the persistent-enable record in
    /// `/var/db/com.apple.xpc.launchd/disabled.plist` either doesn't
    /// stick or isn't honored by launchd on cold boot (TCC clamps the
    /// write, or the auto-load path no longer reads it). So in addition
    /// to bringing ssh up now, we drop a small LaunchDaemon at
    /// `/Library/LaunchDaemons/com.vz.bootstrap-ssh.plist` that
    /// re-runs the bootstrap on every boot. `/Library/LaunchDaemons` is
    /// outside SSV and auto-loaded by launchd on every boot.
    ///
    /// Long shell payloads are hex-encoded and piped through `xxd -r
    /// -p` so the chars we actually have to type into Terminal stay in
    /// `[0-9a-f]` — avoids any remaining edge cases in the keysym path
    /// and sidesteps shell-escaping the pubkey's `+` / `/` / `=`.
    ///
    /// `verifyText("SSHD_OK")` is the retry gate — if any earlier step
    /// misfires (Spotlight didn't open, sudo didn't take the password,
    /// Terminal didn't focus), the trailing echo won't have been issued
    /// and the surrounding retry loop restores from `--restore-from`
    /// and tries again.
    static func provisionSSHSteps(pubkey: String) -> [SetupAssistantSequence.Step] {
        // pubkey + trailing newline so authorized_keys ends with \n.
        let pubkeyHex = (pubkey + "\n").utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // Persistent bootstrap daemon. Runs `launchctl enable +
        // bootstrap` of ssh.plist at every boot, and re-asserts the
        // firewall-off state in case it ever drifts. Owned by root,
        // mode 644 (the launchd loader skips plists with looser perms).
        let bootstrapPlist = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
        <key>Label</key><string>com.vz.bootstrap-ssh</string>
        <key>ProgramArguments</key>
        <array>
        <string>/bin/sh</string>
        <string>-c</string>
        <string>/bin/launchctl enable system/com.openssh.sshd; /bin/launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist; /usr/libexec/ApplicationFirewall/socketfilterfw --setglobalstate off</string>
        </array>
        <key>RunAtLoad</key><true/>
        </dict>
        </plist>
        """
        let bootstrapPlistHex = bootstrapPlist.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // Restoring post-sa and logging in re-runs the per-user first-login
        // Setup Assistant (Apple Account, Location Services, …) in a screen
        // order that varies. Clear it with the dispatch loop until the Finder
        // desktop is the terminal screen.
        let firstLoginRules: [ScreenRule] = [
            ScreenRule(match: "Sign In to Your Apple Account", actions: [
                .clickByText("Other Sign-In Options"), .wait(seconds: 2),
                .clickByText("Sign in Later in Settings"), .wait(seconds: 2),
                .clickByText("Skip"),
            ], terminal: false),
            ScreenRule(match: "Data & Privacy", actions: [.clickByText("Continue")], terminal: false),
            ScreenRule(match: "Accessibility", actions: [.clickByText("Not Now")], terminal: false),
            ScreenRule(match: "Terms and Conditions", actions: [
                .clickByText("Agree"), .wait(seconds: 2), .clickByText("Agree"),
            ], terminal: false),
            ScreenRule(match: "Location Services", actions: [
                .clickByText("Continue"), .wait(seconds: 2), .clickByText("Don't Use"),
            ], terminal: false),
            ScreenRule(match: "Select Your Time Zone", actions: [.clickByText("Continue")], terminal: false),
            ScreenRule(match: "Analytics", actions: [.clickByText("Continue")], terminal: false),
            ScreenRule(match: "Screen Time", actions: [.clickByText("Set Up Later")], terminal: false),
            ScreenRule(match: "FileVault", actions: [
                .clickByText("Not Now"), .wait(seconds: 2), .clickByText("Continue"),
            ], terminal: false),
            ScreenRule(match: "Choose Your Look", actions: [.clickByText("Continue")], terminal: false),
            ScreenRule(match: "Update Mac", actions: [.clickByText("Continue")], terminal: false),
            ScreenRule(match: "Get Started", actions: [.clickByText("Get Started")], terminal: false),
            ScreenRule(match: "Finder", actions: [], terminal: true),
        ]

        return [
            .log("waiting 30s for boot to reach lock screen"),
            .wait(seconds: 30),
            .screenshot(label: "01-lock-screen"),
            .verifyText("admin"),

            // Lock screen: password field is focused by default. Type
            // the password and submit.
            .type("vzvz"),
            .key(.returnKey),
            .wait(seconds: 25),
            .screenshot(label: "02-desktop"),

            .dispatch(rules: firstLoginRules, maxIterations: 40),
            .wait(seconds: 2),
            .screenshot(label: "02b-first-login-cleared"),

            // Spotlight → terminal → Enter. Spotlight matches case-
            // insensitively, so lowercase "terminal" finds Terminal.app.
            .modifiedKey(modifier: .command, key: .space),
            .wait(seconds: 1),
            .type("terminal"),
            .wait(seconds: 1),
            .key(.returnKey),
            .wait(seconds: 6),
            .screenshot(label: "03-terminal"),

            // Install the persistent bootstrap LaunchDaemon. Owned by
            // root, mode 644, in /Library/LaunchDaemons (writable,
            // auto-loaded on every boot). The xxd-decode dance keeps
            // the inline plist content out of zsh's parser.
            .type(
                "printf '\(bootstrapPlistHex)' | xxd -r -p | "
                    + "sudo tee /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist > /dev/null && "
                    + "sudo chmod 644 /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist && "
                    + "sudo chown root:wheel /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist"
            ),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("vzvz"), // sudo password (first sudo of the session)
            .key(.returnKey),
            .wait(seconds: 4),

            // Bootstrap the daemon for the current session — also
            // exercises the same code path the daemon will use on every
            // subsequent boot.
            .type("sudo launchctl bootstrap system /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 5),
            .screenshot(label: "04-bootstrap-daemon"),

            // Install pubkey via hex-decode. `xxd` ships with vim and
            // is in /usr/bin on every macOS install.
            .type(
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
                    + "printf '\(pubkeyHex)' | xxd -r -p > ~/.ssh/authorized_keys && "
                    + "chmod 600 ~/.ssh/authorized_keys && "
                    + "echo PUBKEY_INSTALLED"
            ),
            .key(.returnKey),
            .wait(seconds: 4),
            .screenshot(label: "05-pubkey-installed"),
            .verifyText("PUBKEY_INSTALLED"),

            // Verify sshd is actually listening on port 22 before we
            // snapshot. If `launchctl bootstrap` silently failed (e.g.
            // a future TCC clamp), `lsof` returns non-zero and we hit
            // SSHD_BAD — the surrounding retry loop catches it.
            .type("sudo lsof -nP -iTCP:22 -sTCP:LISTEN >/dev/null 2>&1 && echo SSHD_OK || echo SSHD_BAD"),
            .key(.returnKey),
            .wait(seconds: 3),
            .screenshot(label: "06-sshd-verified"),
            .verifyText("SSHD_OK"),

            // Graceful shutdown so authorized_keys is flushed before
            // the outer runner stops the VM. The sudo timestamp is
            // still warm from the launchctl call, so no second password
            // prompt.
            .type("sudo shutdown -h now"),
            .key(.returnKey),
            .wait(seconds: 10),
            .screenshot(label: "07-shutdown-initiated"),
        ]
    }
}

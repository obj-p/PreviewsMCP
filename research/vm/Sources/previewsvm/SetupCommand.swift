import AppKit
import ArgumentParser
import Darwin
import Foundation
import PreviewsVMKit

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
    var outputDir: String = "/tmp/previewsvm-setup"

    @Flag(
        name: .customLong("invisible"),
        help: "Use the off-screen window (production default). Default is visible at (80,80) so you can watch the run."
    )
    var invisible: Bool = false

    @Option(
        name: .customLong("preset"),
        help: "Which exploratory preset to run."
    )
    var preset: Preset = .exploreEarly

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

    @Flag(
        name: .customLong("recovery"),
        help: "Boot into macOS recoveryOS via VZMacOSVirtualMachineStartOptions.startUpFromMacOSRecovery=true. Required by the recoveryOS-bound presets (explore-recovery, disable-sip)."
    )
    var recovery: Bool = false

    enum Preset: String, ExpressibleByArgument, CaseIterable {
        /// 30s render wait + screenshot, then Enter, screenshot, ...
        /// Goal: figure out what the first 5-6 SA screens look like.
        case exploreEarly = "explore-early"

        /// After Region screen (reached by 5 Enters from Welcome),
        /// methodically map what Tab/Space/Down do. Each labeled step
        /// makes the screenshot filename tell you what we just pressed.
        case exploreTabNav = "explore-tab-nav"

        /// Welcome → Language → Region with a mouse click on Region's
        /// Continue button. Probes whether mouse events delivered via
        /// NSEvent reach the guest the same way keyboard events do.
        case exploreClick = "explore-click"

        /// Same as exploreClick but driven via VNC/RFB transport.
        /// Coordinates are framebuffer pixels, top-left origin.
        case exploreClickVNC = "explore-click-vnc"

        /// Migration-Assistant-only. Assumes the VM boots straight onto
        /// the "Transfer Your Data to This Mac" screen — i.e., that the
        /// bundle has been restored from a `post-region` snapshot. No
        /// Welcome/Language/Region steps.
        case migrationOnly = "migration-only"

        /// Restore from a `post-sa` snapshot, log in as admin, open
        /// Terminal via Spotlight, enable Remote Login, install the
        /// bundle's SSH public key, then `shutdown -h now`. After this
        /// runs successfully, `previewsvm ssh <bundle> -- uname -a`
        /// succeeds and no further OCR is needed downstream.
        case provisionSSH = "provision-ssh"

        /// Boot whatever state the bundle is currently in (no restore),
        /// log in, open Terminal, and print diagnostic information
        /// about the SSH provisioning state to the framebuffer for
        /// human-eyed troubleshooting. Use after a `provision-ssh` run
        /// that didn't survive reboot.
        case debugSSHState = "debug-ssh-state"

        /// Boot into recoveryOS (requires --recovery flag) and
        /// screenshot the UI at intervals so we can see what the
        /// first-render state of recoveryOS looks like on this macOS
        /// version. Doesn't perform any actions — pure observation.
        /// Used to author the `disable-sip` sequence.
        case exploreRecovery = "explore-recovery"

        /// Restore from `post-ssh`, boot into recoveryOS, navigate the
        /// Startup Options picker → Options → user-unlock → macOS
        /// Utilities → Utilities menu → Terminal → `csrutil disable`,
        /// confirm + reboot. Requires --recovery flag.
        case disableSIP = "disable-sip"
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

        let steps: [SetupAssistantSequence.Step]
        switch preset {
        case .exploreEarly: steps = Self.exploreEarlySteps
        case .exploreTabNav: steps = Self.exploreTabNavSteps
        case .exploreClick: steps = Self.exploreClickSteps
        case .exploreClickVNC: steps = Self.exploreClickVNCSteps
        case .migrationOnly: steps = Self.migrationOnlySteps
        case .provisionSSH:
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
            steps = Self.provisionSSHSteps(pubkey: pubkey)
        case .debugSSHState:
            if transport != .vnc {
                throw VMError("--preset debug-ssh-state requires --transport vnc")
            }
            steps = Self.debugSSHStateSteps
        case .exploreRecovery:
            if transport != .vnc {
                throw VMError("--preset explore-recovery requires --transport vnc")
            }
            if !recovery {
                throw VMError("--preset explore-recovery requires --recovery")
            }
            steps = Self.exploreRecoverySteps
        case .disableSIP:
            if transport != .vnc {
                throw VMError("--preset disable-sip requires --transport vnc")
            }
            if !recovery {
                throw VMError("--preset disable-sip requires --recovery")
            }
            steps = Self.disableSIPSteps
        }

        if retry > 0 && restoreFrom == nil {
            throw VMError("--retry > 0 requires --restore-from <snapshot-name>")
        }

        let maxAttempts = retry + 1
        var lastError: Error?
        for attempt in 1...maxAttempts {
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
                at: attemptDir, withIntermediateDirectories: true)

            do {
                try await runOneAttempt(
                    bundle: bundle, steps: steps, screenshotDir: attemptDir)
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
                    steps, host: host, screenshotDir: screenshotDir)
            case .vnc:
                let vnc = try await MainActor.run {
                    try VNCSPI.start(virtualMachine: host.machine, port: 0)
                }
                defer { Task { @MainActor in vnc.stop() } }

                let client = RFBClient()
                try client.connect(to: .init(host: "127.0.0.1", port: vnc.port), timeout: 10)
                try client.handshake()
                Log.info("RFB client ready; running sequence via VNC transport")

                try await SetupAssistantSequence.runVNC(
                    steps, host: host, client: client, screenshotDir: screenshotDir)
            }
        } catch {
            Log.info("sequence threw: \(error.localizedDescription); force-stopping VM")
            try? await host.forceStop()
            await MainActor.run { host.close() }
            throw error
        }

        // The provision-ssh / disable-sip presets end with a graceful
        // halt/shutdown so persistent state (authorized_keys, NVRAM)
        // flushes before the disk image is captured. Wait for the
        // guest to reach `.stopped` on its own; fall back to
        // force-stop if it doesn't.
        if preset == .provisionSSH || preset == .disableSIP {
            do {
                Log.info("sequence complete; waiting up to 30s for graceful guest shutdown")
                try await host.waitForStop(timeout: 30)
                Log.info("guest stopped gracefully")
            } catch {
                Log.info("graceful shutdown did not complete: \(error.localizedDescription); force-stopping")
                try? await host.forceStop()
            }
        } else {
            Log.info("sequence complete; force-stopping VM")
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
    /// `/Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist` that
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
            <key>Label</key><string>com.previewsvm.bootstrap-ssh</string>
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

        return [
            .log("waiting 30s for boot to reach lock screen"),
            .wait(seconds: 30),
            .screenshot(label: "01-lock-screen"),
            .verifyText("admin"),

            // Lock screen: password field is focused by default. Type
            // the password and submit.
            .type("previewsvm"),
            .key(.returnKey),
            .wait(seconds: 25),
            .screenshot(label: "02-desktop"),

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
                + "sudo tee /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist > /dev/null && "
                + "sudo chmod 644 /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist && "
                + "sudo chown root:wheel /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("previewsvm"),  // sudo password (first sudo of the session)
            .key(.returnKey),
            .wait(seconds: 4),

            // Bootstrap the daemon for the current session — also
            // exercises the same code path the daemon will use on every
            // subsequent boot.
            .type("sudo launchctl bootstrap system /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 5),
            .screenshot(label: "04-bootstrap-daemon"),

            // Install pubkey via hex-decode. `xxd` ships with vim and
            // is in /usr/bin on every macOS install.
            .type(
                "mkdir -p ~/.ssh && chmod 700 ~/.ssh && "
                + "printf '\(pubkeyHex)' | xxd -r -p > ~/.ssh/authorized_keys && "
                + "chmod 600 ~/.ssh/authorized_keys && "
                + "echo PUBKEY_INSTALLED"),
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

    /// Pure-observation preset for the recoveryOS UI on this macOS
    /// version. Boots into recovery (via --recovery), waits long
    /// intervals, screenshots throughout. We don't know what the first
    /// screen is, whether user-selection is gated, what menu items
    /// look like — this preset is the eyes-on-it discovery pass.
    /// Authors `disable-sip` from the artifacts.
    static var exploreRecoverySteps: [SetupAssistantSequence.Step] {
        var steps: [SetupAssistantSequence.Step] = [
            .log("recoveryOS boot — screenshotting at intervals for 4 minutes"),
        ]
        // Take a screenshot every 15s. recoveryOS on Apple Silicon
        // can take 60-120s to render its initial UI, and intermediate
        // states (loading, user picker, password prompt, macOS
        // Utilities) are all valuable to see.
        for i in 1...16 {
            steps.append(.wait(seconds: 15))
            steps.append(.screenshot(label: String(format: "t+%03ds", i * 15)))
        }
        return steps
    }

    /// Drive recoveryOS to `csrutil disable`. From the Apple-Silicon
    /// Startup Options picker: click Options → handle user-unlock if
    /// shown → wait for macOS Utilities → Utilities menu → Terminal →
    /// `csrutil disable` → confirm any auth dialog → verify success
    /// marker → halt. After this snapshot, the next normal boot has
    /// SIP off (`csrutil status` shows "System Integrity Protection
    /// status: disabled" over SSH).
    ///
    /// Many unknowns first time through — screenshots between every
    /// step so a failed run tells us exactly where it derailed.
    static var disableSIPSteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 45s for Startup Options picker to render"),
            .wait(seconds: 45),
            .screenshot(label: "01-startup-options"),
            .verifyText("Options"),

            // Apple Silicon Startup Options is a two-step click: the
            // first click on "Options" selects the gear (boxes it in
            // the UI) and reveals a "Continue" button below. The
            // second click on Continue actually transitions into
            // recoveryOS.
            .clickByText("Options"),
            .wait(seconds: 3),
            .verifyText("Continue"),
            .clickByText("Continue"),

            // recoveryOS boot takes ~90s after the Continue click
            // (Apple logo + progress bar phase). Then a Language
            // picker appears with English pre-selected (blue
            // highlight) — Enter advances.
            .wait(seconds: 90),
            .screenshot(label: "02-recovery-language"),
            .verifyText("Language"),
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03-after-language"),

            // After Language → Continue, recoveryOS goes straight to
            // the macOS Utilities window (titled "Recovery" in
            // Tahoe). No user-unlock screen — that only appears when
            // a tool actually requires authentication (e.g., csrutil
            // itself).
            .verifyText("Recovery"),

            // VNC pointer clicks on the macOS menu bar don't open
            // dropdowns in recoveryOS (verified empirically with
            // click holds up to 300ms — the click registers as
            // cursor movement but the menu never opens). Use
            // keyboard navigation instead: Ctrl+F2 focuses the menu
            // bar, then arrow-right to reach Utilities, Down to open
            // its menu, then Down repeatedly to find Terminal and
            // Enter to launch it.
            //
            // Menu bar order: Apple, Recovery, File, Edit, Utilities,
            // Window. Starting from Apple after Ctrl+F2, four rights
            // lands on Utilities.
            .modifiedKey(modifier: .control, key: .f2),
            .wait(seconds: 1),
            .screenshot(label: "04-after-ctrl-f2"),
            .key(.rightArrow),
            .wait(seconds: 0.3),
            .key(.rightArrow),
            .wait(seconds: 0.3),
            .key(.rightArrow),
            .wait(seconds: 0.3),
            .key(.rightArrow),
            .wait(seconds: 0.3),
            .screenshot(label: "05-on-utilities"),

            // Down opens the focused menu.
            .key(.downArrow),
            .wait(seconds: 1),
            .screenshot(label: "06-utilities-open"),

            // Type-ahead: pressing "T" jumps to the first item
            // starting with T (Terminal). Enter activates.
            .type("t"),
            .wait(seconds: 0.5),
            .screenshot(label: "07-terminal-selected"),
            .key(.returnKey),
            .wait(seconds: 5),
            .screenshot(label: "08-terminal-open"),

            // Run csrutil disable. On Apple Silicon recovery, csrutil
            // may prompt for credentials via a system dialog. We'll
            // see what happens in the screenshots and add handling if
            // needed.
            .type("csrutil disable"),
            .key(.returnKey),
            .wait(seconds: 5),
            .screenshot(label: "09-after-csrutil-disable"),

            // First confirmation: y/n prompt asking whether to allow
            // booting unsigned operating systems and kernel extensions
            // for OS "Macintosh HD".
            .type("y"),
            .key(.returnKey),
            .wait(seconds: 3),
            .screenshot(label: "10-after-yn"),

            // Authorized user: admin + Enter (then password).
            .verifyText("Authorized user"),
            .type("admin"),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("previewsvm"),
            .key(.returnKey),
            .wait(seconds: 10),
            .screenshot(label: "11-after-auth"),

            // Success marker on Tahoe is "System Integrity Protection
            // is off." followed by "Restart the machine for the
            // changes to take effect." Use the first as the retry
            // gate.
            .verifyText("System Integrity Protection is off"),

            // Halt (or shutdown). `halt` is shorter than typing
            // shutdown -h now. recoveryOS is root by default so no
            // sudo needed.
            .type("halt"),
            .key(.returnKey),
            .wait(seconds: 10),
            .screenshot(label: "12-after-halt"),
        ]
    }

    /// Diagnostic preset for the `provision-ssh` reboot-persistence
    /// problem. Doesn't restore from a snapshot — runs against whatever
    /// state the bundle is currently in. Prints SSH state to the
    /// terminal framebuffer for screenshot inspection.
    static var debugSSHStateSteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 30s for boot to reach lock screen"),
            .wait(seconds: 30),
            .screenshot(label: "01-lock-screen"),
            .verifyText("admin"),

            .type("previewsvm"),
            .key(.returnKey),
            .wait(seconds: 25),
            .screenshot(label: "02-desktop"),

            .modifiedKey(modifier: .command, key: .space),
            .wait(seconds: 1),
            .type("terminal"),
            .wait(seconds: 1),
            .key(.returnKey),
            .wait(seconds: 6),
            .screenshot(label: "03-terminal"),

            // Is the persistent LaunchDaemon plist on disk?
            .type("ls -la /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist && echo PLIST_EXISTS || echo PLIST_MISSING"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "04-plist-exists"),

            // Is its content parseable?
            .type("plutil -p /Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "05-plist-content"),

            // Did launchd auto-load our daemon? (sudo will prompt.)
            .type("sudo launchctl print system/com.previewsvm.bootstrap-ssh"),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("previewsvm"),
            .key(.returnKey),
            .wait(seconds: 3),
            .screenshot(label: "06-our-daemon-state"),

            // What about the system sshd?
            .type("sudo launchctl print system/com.openssh.sshd 2>&1 | head -20"),
            .key(.returnKey),
            .wait(seconds: 3),
            .screenshot(label: "07-sshd-state"),

            // Is anything listening on port 22?
            .type("sudo lsof -nP -iTCP:22 -sTCP:LISTEN && echo PORT22_LISTENING || echo PORT22_DEAD"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "08-port22"),

            // Manual bootstrap — does this fix it right now?
            .type("sudo launchctl enable system/com.openssh.sshd && sudo launchctl bootstrap system /System/Library/LaunchDaemons/ssh.plist && echo MANUAL_BOOTSTRAP_OK || echo MANUAL_BOOTSTRAP_FAIL"),
            .key(.returnKey),
            .wait(seconds: 4),
            .screenshot(label: "09-manual-bootstrap"),

            .type("sudo lsof -nP -iTCP:22 -sTCP:LISTEN && echo PORT22_NOW_LISTENING || echo PORT22_STILL_DEAD"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "10-port22-after"),

            // Is the application firewall persistent?
            .type("sudo /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "11-firewall-state"),

            // Login Items / Background Item Management — is our daemon
            // approved or held?
            .type("sfltool dumpbtm 2>&1 | head -40"),
            .key(.returnKey),
            .wait(seconds: 3),
            .screenshot(label: "12-btm"),

            .type("sudo shutdown -h now"),
            .key(.returnKey),
            .wait(seconds: 10),
            .screenshot(label: "13-shutdown"),
        ]
    }

    /// Migration Assistant via OCR-driven clicks. Robust against
    /// per-version layout shifts — we click "Set up as new" by name
    /// and "Continue" by name, not by pixel position.
    static var migrationOnlySteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 30s for Setup Assistant to render"),
            .wait(seconds: 30),
            .screenshot(label: "01-migration-pre"),

            .clickByText("Set up as new"),
            .wait(seconds: 2),
            .screenshot(label: "02-after-click-setup-new"),

            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "03-after-continue"),

            .wait(seconds: 5),
            .screenshot(label: "04-settled"),
        ]
    }

    /// VNC variant — the empirically-verified macOS 26 Region
    /// sequence:
    ///
    ///   click(title) → wait → type "united states" → Shift+Tab → Space
    ///
    /// Click the title text (a non-interactive element) to re-establish
    /// window focus that macOS 26 silently lost during boot. Type
    /// "united states" — the list autocomplete-selects. Shift+Tab moves
    /// focus from the type-ahead field to the now-enabled Continue
    /// button. Space activates the focused button. This works around
    /// the failure mode where a list click + Down+Up was insufficient
    /// to enable Continue on its own.
    ///
    /// Coordinates are framebuffer pixels (top-left origin) in the
    /// 1280×720 RFB framebuffer.
    static var exploreClickVNCSteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 30s for Setup Assistant to render"),
            .wait(seconds: 30),
            .screenshot(label: "01-welcome"),

            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "02-language"),
            // Early gate: if we're not on Language, the Welcome Enter
            // didn't fire — retry from base before paying for the rest.
            .verifyText("Language"),

            // Plain Enter advances Language → Region when boot-time
            // focus lands on the list with English highlighted. Boot
            // variability means this fails some % of the time — the
            // retry loop catches it.
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03-region-pre"),
            .verifyText("Select Your Country"),

            // Region screen is the flakiest step in SA — list focus
            // varies boot-to-boot. Defensive triple sequence:
            //   (1) OCR-click the title to re-establish window focus
            //       (Tart-pattern workaround for the macOS 26 focus loss).
            //   (2) Type "united states" — autocomplete-selects on a
            //       focused list, no-op otherwise.
            //   (3) OCR-click "United States" — reinforces selection
            //       in case typing went to the wrong field.
            //   (4) Shift+Tab → Space — focus + activate Continue.
            // Whichever step actually does the work, the others are
            // harmless. Outer retry catches the remaining ~50% of
            // failures.
            .clickByText("Select Your Country"),
            .wait(seconds: 3),
            .type("united states"),
            .wait(seconds: 2),
            .clickByText("United States"),
            .wait(seconds: 2),
            .screenshot(label: "04-after-type"),

            // Shift+Tab to focus the Continue button.
            .modifiedKey(modifier: .shift, key: .tab),
            .wait(seconds: 2),
            .screenshot(label: "05-after-shifttab"),

            // Space activates the focused Continue button.
            .key(.space),
            .wait(seconds: 8),
            .screenshot(label: "06-after-space"),

            // Verify we actually advanced past Region. If we still see
            // "Select Your Country or Region", the flaky transition
            // didn't fire — outer retry loop restores base and tries
            // again.
            .verifyText("Transfer Your Data"),

            // === Migration Assistant ("Transfer Your Data to This Mac") ===
            // OCR-driven clicks: find UI elements by text, no pixel
            // coordinate calibration needed. Tart's macos-image-templates
            // uses the same approach for the same reason.
            .log("Migration Assistant: OCR-click 'Set up as new' + 'Continue'"),
            .clickByText("Set up as new"),
            .wait(seconds: 2),
            .screenshot(label: "07-after-click-setup-new"),

            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "08-after-migration-continue"),

            // === Written and Spoken Languages ===
            // No selection needed; the defaults (English, US input,
            // English dictation) are populated from the region. Just
            // Continue.
            .verifyText("Written and Spoken Languages"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "09-after-languages-continue"),

            // === Accessibility ===
            // Categories (Vision, Motor, Hearing, Cognitive). Skip
            // entirely via "Not Now" — features can be set up later
            // in System Settings.
            .verifyText("Accessibility"),
            .clickByText("Not Now"),
            .wait(seconds: 8),
            .screenshot(label: "10-after-accessibility-skip"),

            // === Data & Privacy ===
            // Informational; just Continue.
            .verifyText("Data & Privacy"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "11-after-privacy-continue"),

            // === Create a Mac Account ===
            // Hard-coded credentials: full name "admin", password
            // "previewsvm". The bundle's sshUsername in config.json
            // matches. Tab traversal between fields: from Full Name
            // → Account Name (auto-filled) → Password → Verify Password
            // → Hint → Continue.
            .verifyText("Create a Mac Account"),
            .clickByText("Full Name"),
            .wait(seconds: 1),
            .type("admin"),
            .wait(seconds: 0.5),
            .key(.tab),
            .wait(seconds: 0.5),
            .key(.tab),  // skip Account Name (auto-fills from Full Name)
            .wait(seconds: 0.5),
            .type("previewsvm"),  // Password
            .wait(seconds: 0.5),
            .key(.tab),
            .wait(seconds: 0.5),
            .type("previewsvm"),  // Verify Password
            .wait(seconds: 1),
            .screenshot(label: "12-account-filled"),

            .clickByText("Continue"),
            // Account creation is the slowest step — macOS provisions
            // the home dir, dslocal records, indexes etc. We caught
            // "Creating account..." still showing after 20s, so give
            // it a full minute.
            .wait(seconds: 60),
            .screenshot(label: "13-after-account-continue"),

            // === Sign In to Your Apple Account ===
            // Skip — "Set Up Later" is bottom-left. macOS pops a
            // confirmation dialog with "Don't Skip" / "Skip" buttons.
            // Exact-match-preferred OCR find picks "Skip" reliably
            // (not "Don't Skip" by substring).
            .verifyText("Sign In to Your Apple Account"),
            .clickByText("Set Up Later"),
            .wait(seconds: 3),
            .clickByText("Skip"),
            .wait(seconds: 8),
            .screenshot(label: "14-after-appleid-skip"),

            // === Terms and Conditions ===
            // macOS Software License Agreement. First Agree click opens
            // a "I have read and agree..." confirmation modal; second
            // Agree click confirms. FramebufferOCR.find prefers
            // exact-text matches, so "Agree" reliably picks the right
            // button (not "Disagree").
            .verifyText("Terms and Conditions"),
            .clickByText("Agree"),
            .wait(seconds: 3),
            .clickByText("Agree"),
            .wait(seconds: 8),
            .screenshot(label: "15-after-tc-agree"),

            // === Enable Location Services ===
            // Skip: leave the checkbox unchecked, click Continue. macOS
            // pops a confirmation if you don't enable it.
            .verifyText("Location Services"),
            .clickByText("Continue"),
            .wait(seconds: 3),
            // Confirmation: "Are you sure you don't want to use Location
            // Services?" with "Don't Use" / "Use" or similar. Click
            // "Don't Use" (or whichever skips).
            .clickByText("Don't Use"),
            .wait(seconds: 8),
            .screenshot(label: "16-after-location"),

            // === Select Your Time Zone ===
            // Default is Cupertino/Pacific from the macOS guest's
            // hardware — fine for a research VM. Just Continue.
            .verifyText("Time Zone"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "17-after-timezone"),

            // === Analytics ===
            // Defaults: Share Mac Analytics with Apple ON, share with
            // app developers OFF. Keep defaults; just Continue.
            .verifyText("Analytics"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "18-after-analytics"),

            // === Screen Time ===
            // Parental controls feature; skip via "Set Up Later".
            .verifyText("Screen Time"),
            .clickByText("Set Up Later"),
            .wait(seconds: 8),
            .screenshot(label: "19-after-screentime"),

            // === FileVault ===
            // Disk encryption — skip on a research VM. macOS pops a
            // "Mac Data Will Not Be Securely Encrypted" confirmation;
            // Continue is the default-highlighted button.
            .verifyText("FileVault"),
            .clickByText("Not Now"),
            .wait(seconds: 3),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "20-after-filevault"),

            // === Choose Your Look ===
            // Light/Auto/Dark appearance picker. Light is the default
            // (highlighted blue); just Continue.
            .verifyText("Choose Your Look"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "21-after-look"),

            // === Update Mac Automatically ===
            // Auto-update settings. Continue accepts the default
            // auto-update behavior. For a research VM that's snapshot-
            // restored every session, the auto-update setting is moot.
            .verifyText("Update Mac"),
            .clickByText("Continue"),
            .wait(seconds: 8),
            .screenshot(label: "22-after-update"),

            // === Final Welcome ("welcome" cursive + Get Started) ===
            // Last screen — clicking "Get Started" enters the desktop.
            .verifyText("Get Started"),
            .clickByText("Get Started"),
            .wait(seconds: 20),
            .screenshot(label: "23-after-get-started"),

            .wait(seconds: 10),
            .screenshot(label: "24-desktop"),
        ]
    }

    /// Mouse-click trial: get to the Region screen, then click where
    /// the Continue button lives. Window content is 1280x720
    /// (bottom-left origin), framebuffer is 1920x1080; Continue lives
    /// at about pixel-y=1340 of a 1640-tall capture, which after the
    /// 2.1× scale-up corresponds to roughly window-y=130. The x
    /// estimate is the center-right of the SA panel (~540 window-x).
    /// If this click registers, the Continue button activates and the
    /// guest advances; if not, we need different coords or to click
    /// somewhere else first.
    static var exploreClickSteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 30s for Setup Assistant to render"),
            .wait(seconds: 30),
            .screenshot(label: "01-welcome"),

            // Welcome → Language (Enter advances Welcome cleanly).
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "02-language"),

            // Language → Region (one more Enter while English is selected).
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03-region-pre-click"),

            // Click on US in the list to give it explicit focus.
            .click(x: 480, y: 540),
            .wait(seconds: 3),
            .screenshot(label: "04-after-list-click"),

            // Now that the list is focused with US selected, press
            // Enter — many SA-style lists treat this as "confirm".
            .key(.returnKey),
            .wait(seconds: 4),
            .screenshot(label: "05-after-list-click-enter"),

            // If that didn't advance, try clicking Continue at the
            // corrected coordinates (image-x ≈ 1320 → window-x ≈ 627).
            .click(x: 627, y: 130),
            .wait(seconds: 6),
            .screenshot(label: "06-after-continue-click"),

            // One more settle screenshot.
            .wait(seconds: 4),
            .screenshot(label: "07-settled"),
        ]
    }

    /// More methodical exploration: longer waits (8s) between each
    /// keystroke, labeled screenshots so the filename names the key we
    /// just sent. Goal: identify which keys advance Language and which
    /// enable Region's Continue button.
    static var exploreTabNavSteps: [SetupAssistantSequence.Step] {
        [
            .log("waiting 30s for Setup Assistant to render"),
            .wait(seconds: 30),
            .screenshot(label: "01-welcome"),

            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "02-after-enter"),

            .key(.tab),
            .wait(seconds: 3),
            .screenshot(label: "03-after-tab"),

            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "04-after-tab-enter"),

            .key(.space),
            .wait(seconds: 8),
            .screenshot(label: "05-after-space"),

            .key(.downArrow),
            .wait(seconds: 3),
            .screenshot(label: "06-after-down"),

            .key(.upArrow),
            .wait(seconds: 3),
            .screenshot(label: "07-after-up"),

            .key(.tab),
            .wait(seconds: 3),
            .screenshot(label: "08-after-tab-2"),

            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "09-after-tab-enter-2"),

            .key(.tab),
            .wait(seconds: 3),
            .screenshot(label: "10-after-tab-3"),

            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "11-after-tab-enter-3"),
        ]
    }

    /// Exploratory script: 30s SA-render wait, then alternate
    /// (screenshot → Enter → 3s wait) for ~8 cycles. Whatever screens
    /// SA shows in that window get captured; we then replace this with
    /// a real per-screen script.
    static var exploreEarlySteps: [SetupAssistantSequence.Step] {
        var steps: [SetupAssistantSequence.Step] = [
            .log("waiting 30s for Setup Assistant to render"),
            .wait(seconds: 30),
            .screenshot(label: "after-boot"),
        ]
        for i in 1...8 {
            steps.append(.log("cycle \(i): Enter, wait 3s, screenshot"))
            steps.append(.key(.returnKey))
            steps.append(.wait(seconds: 3))
            steps.append(.screenshot(label: "after-enter-\(i)"))
        }
        return steps
    }
}

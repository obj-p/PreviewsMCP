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

        /// Drive Xcode in the VM to capture XCPreviewAgent's
        /// __xojit_executor_write_mem call sequence during a real
        /// SwiftUI preview hot-reload. The W3 patch-point address-list
        /// capture from prompts/jit-executor-research.md.
        ///
        /// Preconditions: VM bundle has admin auto-login configured
        /// (`/etc/kcpassword` + `autoLoginUser=admin` in
        /// `com.apple.loginwindow`), `xcodebuild -runFirstLaunch` has
        /// been run, and the source file at
        /// `~/HelloPreview/Sources/HelloPreview/main.swift` exists
        /// (plus a sibling `Package.swift` declaring an executable
        /// target). The preset boots the VM, opens Xcode via SSH,
        /// toggles the preview canvas via VNC keystrokes, runs
        /// `research/scripts/data/w3/capture-write-mem.d` against the
        /// spawned XCPreviewAgent, and triggers an edit by `sed`-ing
        /// the source file (Xcode's file watcher picks it up and
        /// initiates the hot-reload). Output files retrieved over SSH
        /// to `--output-dir`.
        case driveXcodePreview = "drive-xcode-preview"
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
        case .driveXcodePreview:
            if transport != .vnc {
                throw VMError("--preset drive-xcode-preview requires --transport vnc (needs dual modifier keys for Cmd+Option+Return)")
            }
            steps = Self.driveXcodePreviewSteps(
                bundlePath: bundle.url.path,
                outputDir: outDir.path)
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

    /// Drive Xcode in the VM to capture XCPreviewAgent's
    /// `__xojit_executor_write_mem` call sequence during a real SwiftUI
    /// preview hot-reload. The W3 patch-point address-list capture from
    /// `prompts/jit-executor-research.md` →
    /// `research/scripts/analysis/w3-patch-point-set.md` §6.
    ///
    /// **Preconditions** (a `post-autologin-w3`-style snapshot should
    /// already have these):
    /// - admin auto-login configured via `/etc/kcpassword` + the
    ///   `autoLoginUser` default in `com.apple.loginwindow`.
    /// - `xcodebuild -runFirstLaunch` has been run (clears the
    ///   "additional components" first-launch modal).
    /// - `~/HelloPreview/{Package.swift,Sources/HelloPreview/main.swift}`
    ///   contains a minimal SwiftUI executable with a `#Preview` block.
    ///
    /// **Flow:**
    /// 1. Boot. Wait for auto-login to admin's desktop.
    /// 2. SSH-open `main.swift` in Xcode (`open -a /Applications/Xcode.app`).
    /// 3. Wait 90s for Xcode + SourceKit indexing to settle.
    /// 4. Cmd+Option+Return via VNC to toggle the preview canvas. This
    ///    is the only keystroke the preset delivers; everything else
    ///    runs via SSH.
    /// 5. Wait for `XCPreviewAgent` to spawn (poll `pgrep` via SSH).
    /// 6. Deploy the `capture-write-mem.d` dtrace script to the guest
    ///    (hex-encoded inline; SSH-decodes via `xxd -r -p`). Start it
    ///    against the agent PID under `sudo`.
    /// 7. Edit `main.swift` via `sed` (`Hello` → `Howdy`). Xcode's
    ///    file watcher initiates the hot-reload through previewsd to
    ///    the agent; PreviewsInjection calls `__xojit_executor_write_mem`
    ///    to apply patches; dtrace records each call.
    /// 8. Wait 20s for the reload + writes to finish.
    /// 9. Stop dtrace, retrieve output via SSH `cat`.
    static func driveXcodePreviewSteps(
        bundlePath: String,
        outputDir: String
    ) -> [SetupAssistantSequence.Step] {
        let previewsvmBin = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? "previewsvm"
        let ssh = "\"\(previewsvmBin)\" ssh \"\(bundlePath)\""

        // The dtrace script lives in research/scripts/data/w3/capture-write-mem.d
        // (committed). Embedded here so the preset is self-contained — no
        // separate file deploy step needed when this preset runs from a CI
        // job with no working copy.
        let dtraceScript = """
            #pragma D option quiet
            #pragma D option dynvarsize=8m
            #pragma D option strsize=512

            dtrace:::BEGIN {
                printf("[capture-write-mem] tracing pid=%d (XCPreviewAgent)\\n", $target);
                printf("ts\\twrite_mem(addr, len)\\n");
            }

            pid$target::*xojit_executor_write_mem*:entry {
                printf("%llu\\twrite_mem(0x%llx, %lld)\\n", timestamp, (uint64_t)arg0, (int64_t)arg2);
                ustack(5);
                printf("\\n");
            }

            pid$target::*xojit_executor_run_program_on_main_thread*:entry {
                printf("%llu\\trun_program_on_main_thread(fn=0x%llx)\\n", timestamp, (uint64_t)arg0);
                ustack(3);
                printf("\\n");
            }

            pid$target::mprotect:entry {
                printf("%llu\\tmprotect(addr=0x%llx, len=0x%llx, prot=0x%x)\\n",
                       timestamp, (uint64_t)arg0, (uint64_t)arg1, (uint32_t)arg2);
            }

            dtrace:::END { printf("[capture-write-mem] done\\n"); }
            """
        let dtraceHex = dtraceScript.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // lldb-driven capture script. Used as a fallback when dtrace's
        // pid-provider fails on the agent (Apple gates dtrace on
        // signed binaries separately from SIP). lldb attaches to any
        // get-task-allow process. The script installs Python callback
        // breakpoints that print register state + a short stack on
        // each hit, then resumes execution automatically.
        // Use plain lldb commands (no Python) — lldb's batch mode
        // (`-b`) does not interactively enter the Python REPL via
        // `script`; multi-line Python code in a script file is
        // dispatched line-by-line to the REPL and produces syntax
        // errors. Pure lldb commands with `br command add ... DONE`
        // are the documented batch-friendly form. Each breakpoint's
        // command body ends with `continue` for auto-resume.
        //
        // Symbol-name convention: dyld_info shows the raw Mach-O
        // symbol with linker-added leading `_` (so
        // `___xojit_executor_write_mem` — 3 underscores). lldb's
        // `--name` strips that prefix to match the C function name
        // (`__xojit_executor_write_mem` — 2 underscores). Use the
        // 2-underscore form for breakpoints. The regex fallback
        // catches any naming-convention surprise.
        let lldbScript = """
            settings set target.process.thread.step-avoid-libraries libsystem_kernel.dylib,libsystem_pthread.dylib
            br set --name __xojit_executor_write_mem
            br command add
            printf "WRITE_MEM addr=0x%llx buf=0x%llx len=%lld\\n" $x0 $x1 $x2
            thread backtrace 5
            continue
            DONE
            br set -r xojit_executor_write_mem
            br command add
            printf "WRITE_MEM_RE addr=0x%llx buf=0x%llx len=%lld\\n" $x0 $x1 $x2
            thread backtrace 3
            continue
            DONE
            br set --name __xojit_executor_run_program_on_main_thread
            br command add
            printf "RUN_PROGRAM_MAIN fn=0x%llx\\n" $x0
            continue
            DONE
            br set --name mprotect
            br command add
            printf "MPROTECT addr=0x%llx len=0x%llx prot=0x%x\\n" $x0 $x1 $x2
            continue
            DONE
            br list
            continue
            """
        let lldbScriptHex = lldbScript.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // The `previewsvm ssh` subcommand joins remoteCommand args with
        // a single space and hands the result to `ssh ... user@host
        // <command>`. We pass the entire remote command as ONE
        // argument (the no-`--` form) so previewsvm's
        // ArgumentParser captures it cleanly as a single-element
        // remoteCommand array. The single-argument form with embedded
        // shell-escaped quotes is what works empirically (`--` form
        // confuses /usr/bin/ssh's argv parsing).
        func remote(_ shellCommand: String) -> String {
            // Escape any single quotes inside the command so we can
            // wrap the whole thing in single quotes for previewsvm's
            // argv. Replaces ' with '\''.
            let escaped = shellCommand.replacingOccurrences(of: "'", with: "'\\''")
            return "\(ssh) '\(escaped)'"
        }

        return [
            .log("waiting 35s for boot + (maybe) lock-screen to render"),
            .wait(seconds: 35),
            .screenshot(label: "01a-pre-unlock"),

            // The VM's GUI session may be at the lock screen even when
            // `/dev/console` shows `admin` (auto-login fires but Aqua
            // re-locks shortly after first paint, or never logs in at
            // all). Type the admin password + Return; harmless if the
            // screen is already unlocked (Finder doesn't accept text
            // input on the desktop), unlocks it if locked.
            .log("typing password + Return (unlocks lock screen if up)"),
            .type("previewsvm"),
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "01b-post-unlock"),

            // Keep the display awake + disable screen lock for this
            // session — long waits otherwise cause the display to
            // power off, breaking subsequent keystrokes. `caffeinate
            // -dis` runs until the session ends.
            .hostShell(
                command: remote("(nohup caffeinate -dis > /dev/null 2>&1 &); sleep 1; pgrep caffeinate > /dev/null && echo CAFFEINATE_OK || echo CAFFEINATE_FAILED"),
                label: "start caffeinate",
                expectContains: "CAFFEINATE_OK"),
            .hostShell(
                command: remote("stat -f %Su /dev/console"),
                label: "verify admin console",
                expectContains: "admin"),
            .screenshot(label: "01c-desktop"),

            // Deploy the dtrace script + clean any stale agent state.
            .hostShell(
                command: remote("printf %s \(dtraceHex) | xxd -r -p > /tmp/capture-write-mem.d && wc -l /tmp/capture-write-mem.d"),
                label: "deploy dtrace script"),
            .hostShell(
                command: remote("pkill -9 -f XCPreviewAgent 2>/dev/null; pkill -9 -f Xcode 2>/dev/null; sleep 2; pgrep -f Xcode || echo XCODE_CLEAN"),
                label: "kill stale Xcode/agent",
                expectContains: "XCODE_CLEAN"),

            // Rebuild the test package as a LIBRARY target (no @main,
            // no main.swift top-level conflict). The previous structure
            // had `@main struct HelloApp: App` in a file named
            // main.swift, which Swift rejects (\"main attribute cannot
            // be used in a module that contains top-level code\") and
            // the resulting build error stops preview rendering from
            // ever activating XCPreviewAgent. Library target with a
            // single ContentView.swift containing only the View type
            // and the #Preview block compiles cleanly.
            .hostShell(
                command: remote("rm -rf /Users/admin/HelloPreview && mkdir -p /Users/admin/HelloPreview/Sources/HelloPreview && cat > /Users/admin/HelloPreview/Package.swift << 'PKEOF'\n// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"HelloPreview\",\n    platforms: [.macOS(.v14)],\n    targets: [.target(name: \"HelloPreview\")]\n)\nPKEOF\ncat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    public var body: some View {\n        VStack {\n            Text(\"Hello\").font(.title)\n            Text(\"World\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 120)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\nls -la /Users/admin/HelloPreview/Sources/HelloPreview/ && echo PKG_REBUILT"),
                label: "rebuild test package as library",
                expectContains: "PKG_REBUILT"),

            // Suppress Xcode's "Introducing Coding Intelligence"
            // welcome modal that otherwise blocks keystroke delivery
            // to the source editor on first project open. Best-effort:
            // try a few plausible key names. If none matches, the
            // .key(.escape) step after Xcode launches still dismisses
            // the dialog as a fallback.
            .hostShell(
                command: remote("for k in IDECodingIntelligenceWelcomeShown IDEIntelligenceWelcomeShown DVTIntelligenceWelcomeShown IDECodingIntelligenceFTUXShown; do defaults write com.apple.dt.Xcode \"$k\" -bool YES; done; echo DEFAULTS_SET"),
                label: "suppress Xcode coding-intelligence welcome",
                expectContains: "DEFAULTS_SET"),

            // Open Package.swift in Xcode (gives project context),
            // then main.swift (focuses on the source file with #Preview).
            // Opening main.swift directly without project context skips
            // package indexing and the preview pipeline never activates.
            .hostShell(
                command: remote("open -a /Applications/Xcode.app /Users/admin/HelloPreview/Package.swift && echo OPENED_PKG"),
                label: "open Package.swift in Xcode",
                expectContains: "OPENED_PKG"),
            .log("waiting 30s for project to load"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("open -a /Applications/Xcode.app /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && echo OPENED_MAIN"),
                label: "open ContentView.swift in same Xcode",
                expectContains: "OPENED_MAIN"),
            .log("waiting 60s for SourceKit indexing"),
            .wait(seconds: 60),
            .screenshot(label: "02-xcode-open"),

            // Xcode 26 shows a "Coding Intelligence Welcome" modal
            // sheet on first project open in a fresh user account.
            // It captures all keystrokes until dismissed. Press
            // Escape (cancels) and also click "Remind Me Later" as
            // a fallback. Both target the same outcome — modal is
            // dismissed.
            .log("dismiss any first-run modal sheets"),
            .key(.escape),
            .wait(seconds: 2),
            .key(.escape),
            .wait(seconds: 2),
            .screenshot(label: "02a-after-escape-modal"),

            // Click in the middle of the editor area to make sure the
            // source-editor view is firstResponder before sending
            // canvas-toggle keystrokes. Framebuffer coords (top-left
            // origin), VNC transport.
            .click(x: 600, y: 350),
            .wait(seconds: 2),
            .screenshot(label: "02b-clicked-editor"),

            // Sanity check that keystrokes reach Xcode: send Cmd+,
            // (preferences). If the preferences pane appears in the
            // next screenshot, the keystroke path works. We close it
            // with Escape immediately. Comma's mac keycode is 43,
            // unicode 0x2C.
            .modifiedKey(
                modifier: .command,
                key: .character(unicodeScalar: 0x2C, code: 43)),
            .wait(seconds: 4),
            .screenshot(label: "02c-pref-keystroke-test"),
            .key(.escape),
            .wait(seconds: 2),
            .screenshot(label: "02d-after-escape"),

            // Re-click editor area to re-focus (prefs interaction
            // may have stolen focus to a different view).
            .click(x: 400, y: 300),
            .wait(seconds: 2),

            // Cmd+Option+Return toggles the preview canvas in Xcode 26.
            // This is the load-bearing keystroke. Try it once with a
            // short observation window.
            .log("attempt 1: Cmd+Option+Return"),
            .dualModifiedKey(mod1: .command, mod2: .option, key: .returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03a-after-cmdoptreturn"),

            // Some Xcode 26 builds bound the canvas to Cmd+Shift+Return
            // instead. Try as fallback.
            .log("attempt 2: Cmd+Shift+Return"),
            .dualModifiedKey(mod1: .command, mod2: .shift, key: .returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03b-after-cmdshiftreturn"),

            // Some builds: Cmd+Ctrl+Return (Editor → Canvas alternate).
            .log("attempt 3: Cmd+Control+Return"),
            .dualModifiedKey(mod1: .command, mod2: .control, key: .returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03c-after-cmdctrlreturn"),

            // Cmd+Opt+P — Resume Preview. Triggers preview rendering
            // if the canvas is already open (which it may be by
            // default in Xcode 26, just in a paused state).
            // P's mac keycode is 35, unicode 0x70.
            .log("attempt 4: Cmd+Option+P (resume preview)"),
            .dualModifiedKey(
                mod1: .command, mod2: .option,
                key: .character(unicodeScalar: 0x70, code: 35)),
            .wait(seconds: 8),
            .screenshot(label: "03d-after-cmdoptp"),

            // attempt 5: Use Help menu search (Cmd+? = Cmd+Shift+/).
            // The Help menu's search field activates any menu item by
            // name regardless of its keyboard shortcut. Type "Canvas"
            // → autocomplete highlights the Editor menu's Canvas item
            // → Return activates it. Works universally even if the
            // shortcut has been repurposed (Xcode 26 gave Cmd+Opt+Return
            // to Coding Intelligence). Slash mac keycode = 44, unicode
            // 0x2F. Help-shortcut is Shift+Cmd+/.
            .log("attempt 5: Help → search 'Canvas' → Return"),
            .dualModifiedKey(
                mod1: .command, mod2: .shift,
                key: .character(unicodeScalar: 0x2F, code: 44)),
            .wait(seconds: 2),
            .screenshot(label: "03e-help-menu-open"),
            .type("Canvas"),
            .wait(seconds: 3),
            .screenshot(label: "03f-help-typed-canvas"),
            // Help menu search highlights results on hover but Return
            // only fires the item when keyboard-selected. Down-arrow
            // moves focus to the first result.
            .key(.downArrow),
            .wait(seconds: 1),
            .screenshot(label: "03f2-after-down-arrow"),
            .key(.returnKey),
            .wait(seconds: 8),
            .screenshot(label: "03g-after-help-canvas-enter"),

            .log("waiting 60s for canvas + preview-pipeline to spawn agent"),
            .wait(seconds: 60),
            .screenshot(label: "03-canvas-shown"),

            // Wait for XCPreviewAgent to actually be running. Poll up
            // to 90 seconds (preview-pipeline cold start can be slow
            // first time).
            .hostShell(
                command: remote("for i in $(seq 1 45); do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then echo AGENT_UP $AP; exit 0; fi; sleep 2; done; ps aux | grep -iE 'preview|xcpreview' | grep -v grep; echo AGENT_NOT_FOUND"),
                label: "wait for XCPreviewAgent",
                expectContains: "AGENT_UP"),
            .screenshot(label: "04-agent-up"),

            // dtrace's pid-provider fails on the agent ("Failed to
            // start process notifications") even with SIP off + AMFI
            // off — Apple's dtrace has a separate (csops-checked)
            // gate on attaching to Apple-signed binaries. Use lldb
            // instead: it attaches to any debuggable process (the
            // agent's `get-task-allow` entitlement is sufficient),
            // sets breakpoints on the four xojit primitives, and
            // prints addr/len/stack on each hit via the breakpoint
            // command + auto-continue. The lldb script is deployed
            // to the guest via xxd-hex.
            .hostShell(
                command: remote("printf %s \(lldbScriptHex) | xxd -r -p > /tmp/capture-write-mem.lldb && wc -l /tmp/capture-write-mem.lldb && echo LLDB_DEPLOYED"),
                label: "deploy lldb capture script",
                expectContains: "LLDB_DEPLOYED"),
            .hostShell(
                command: remote("AGENT_PID=$(pgrep -n -f XCPreviewAgent); echo $AGENT_PID > /tmp/w3-agent.pid; rm -f /tmp/w3-writes.lldb.txt; (echo previewsvm | sudo -S env TERM=xterm-256color nohup lldb -b -O 'target create --arch arm64e /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent' -O \"process attach -p $AGENT_PID\" -s /tmp/capture-write-mem.lldb > /tmp/w3-writes.lldb.txt 2>&1 &); sleep 12; pgrep -n lldb && head -70 /tmp/w3-writes.lldb.txt && echo LLDB_STARTED || (cat /tmp/w3-writes.lldb.txt; echo LLDB_FAILED)"),
                label: "start lldb against XCPreviewAgent",
                expectContains: "LLDB_STARTED"),
            .screenshot(label: "05-lldb-running"),

            // Trigger the hot-reload by editing the file via sed.
            // Xcode's file watcher detects the change and routes
            // through previewsd → agent → PreviewsInjection →
            // XOJITExecutor.write_mem. dtrace records the calls.
            .hostShell(
                command: remote("sed -i.bak s/Hello/Howdy/g /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && grep Howdy /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && echo EDITED"),
                label: "edit ContentView.swift (Hello → Howdy)",
                expectContains: "EDITED"),
            .log("waiting 30s for hot-reload + write_mem calls"),
            .wait(seconds: 30),
            .screenshot(label: "06-after-edit"),

            // Stop lldb and retrieve the output. The output is the
            // patch-point address list we wanted.
            .hostShell(
                command: remote("echo previewsvm | sudo -S pkill -INT lldb; sleep 2; wc -l /tmp/w3-writes.lldb.txt; echo ---WRITE_MEM_HITS---; grep WRITE_MEM /tmp/w3-writes.lldb.txt | head -30; echo ---MPROTECT_HITS---; grep MPROTECT /tmp/w3-writes.lldb.txt | head -10"),
                label: "stop lldb + peek output"),
            .hostShell(
                command: remote("cat /tmp/w3-writes.lldb.txt") + " > \"\(outputDir)/w3-writes.lldb.txt\" && wc -l \"\(outputDir)/w3-writes.lldb.txt\"",
                label: "retrieve lldb output to host"),
            .screenshot(label: "07-complete"),
            .log("lldb output retrieved to \(outputDir)/w3-writes.lldb.txt"),
        ]
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

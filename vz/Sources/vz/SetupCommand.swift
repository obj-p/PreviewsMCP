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
        /// runs successfully, `vz ssh <bundle> -- uname -a`
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

        let dispatchRules: [ScreenRule]?
        let dispatchMaxIterations: Int
        if let planPath = plan {
            if transport != .vnc {
                throw VMError("--plan requires --transport vnc")
            }
            let loaded = try SetupPlan.load(
                from: URL(fileURLWithPath: (planPath as NSString).expandingTildeInPath))
            dispatchRules = try loaded.screenRules()
            dispatchMaxIterations = loaded.maxIterations ?? 60
        } else {
            dispatchRules = nil
            dispatchMaxIterations = 60
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
                    bundle: bundle, steps: steps, dispatchRules: dispatchRules,
                    dispatchMaxIterations: dispatchMaxIterations, screenshotDir: attemptDir)
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

                if let dispatchRules {
                    try await SetupAssistantSequence.runDispatchVNC(
                        rules: dispatchRules, host: host, client: client,
                        screenshotDir: screenshotDir,
                        maxIterations: dispatchMaxIterations)
                } else {
                    try await SetupAssistantSequence.runVNC(
                        steps, host: host, client: client, screenshotDir: screenshotDir)
                }
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
    /// **Capture mechanism: DYLD_INSERT_LIBRARIES interposer.** Previous
    /// lldb + dtrace attempts both failed against the attached agent
    /// (lldb: "No executable module" on attach; dtrace: signed-binary
    /// gate independent of SIP/AMFI). The interposer bypasses both:
    /// a small dylib built from `interposer.c` registers a
    /// `__DATA,__interpose` table mapping the four
    /// `__xojit_executor_*` exports to logging wrappers. `launchctl
    /// setenv DYLD_INSERT_LIBRARIES` plus `DYLD_FORCE_FLAT_NAMESPACE=1`
    /// before Xcode launches gets the dylib loaded into every
    /// descendant process, including XCPreviewAgent.
    ///
    /// **Preconditions** (a `post-autologin-w3`-style snapshot should
    /// already have these):
    /// - admin auto-login configured via `/etc/kcpassword` + the
    ///   `autoLoginUser` default in `com.apple.loginwindow`.
    /// - `xcodebuild -runFirstLaunch` has been run (clears the
    ///   "additional components" first-launch modal).
    /// - `~/HelloPreview/{Package.swift,Sources/HelloPreview/ContentView.swift}`
    ///   contains a minimal SwiftUI library target with a `#Preview` block
    ///   (the preset rebuilds this each run from scratch — see
    ///   "rebuild test package as library" step).
    ///
    /// **Flow:**
    /// 1. Boot. Wait for auto-login to admin's desktop.
    /// 2. Kill stale Xcode/agent.
    /// 3. Build the interposer dylib on the guest from embedded C
    ///    source (clang ships with Xcode's toolchain).
    /// 4. `launchctl setenv DYLD_INSERT_LIBRARIES /tmp/w3-interposer.dylib`
    ///    + `launchctl setenv DYLD_FORCE_FLAT_NAMESPACE 1`. Subsequent
    ///    launchd-spawned processes inherit this env, incl. Xcode and
    ///    its previewsd descendant.
    /// 5. Open Package.swift then ContentView.swift in Xcode.
    /// 6. Drive the preview canvas open via Help-menu search ("Canvas").
    ///    Xcode 26 repurposed Cmd+Opt+Return so the menu-search path
    ///    is the load-bearing one.
    /// 7. Wait for `XCPreviewAgent` to spawn (poll `pgrep` via SSH).
    /// 8. Diagnostic: verify the agent has DYLD_INSERT_LIBRARIES via
    ///    `ps -E` and that `/tmp/w3-interposer.log` recorded a
    ///    constructor call from an XCPreviewAgent process.
    /// 9. Edit ContentView.swift via `sed` (`Hello` → `Howdy`). Xcode's
    ///    file watcher initiates the hot-reload through previewsd to
    ///    the agent; PreviewsInjection calls `__xojit_executor_write_mem`
    ///    to apply patches; the interposer wrapper logs each call.
    /// 10. Wait 30s for the reload + writes to finish.
    /// 11. Retrieve `/tmp/w3-writes.log` (the W3 address-list deliverable)
    ///     and `/tmp/w3-interposer.log` (load-time diagnostic).
    static func driveXcodePreviewSteps(
        bundlePath: String,
        outputDir: String
    ) -> [SetupAssistantSequence.Step] {
        let vzBin = Bundle.main.executableURL?.path
            ?? CommandLine.arguments.first
            ?? "vz"
        let ssh = "\"\(vzBin)\" ssh \"\(bundlePath)\""

        // DYLD_INSERT_LIBRARIES interposer source. The previous attempt's
        // lldb + dtrace paths both failed: lldb couldn't resolve symbols
        // on the attached agent ("No executable module"), and dtrace's
        // pid-provider is gated on signed-binary checks separate from
        // SIP. The interposer bypasses both. The dylib is built on the
        // guest from this embedded source (clang ships with Xcode and
        // is on PATH after `xcode-select` has run).
        //
        // The committed master copy lives at
        // `research/scripts/data/w3/interposer.c`; this string mirrors
        // it so the preset is self-contained. Keep them in sync.
        let interposerC = #"""
            // W3 — DYLD_INSERT_LIBRARIES interposer dylib. See
            // research/scripts/data/w3/interposer.c for the committed copy.
            #include <stdio.h>
            #include <stdint.h>
            #include <unistd.h>
            #include <pthread.h>
            #include <string.h>
            #include <sys/time.h>
            #include <mach-o/dyld.h>

            static FILE *g_log = NULL;
            static pthread_mutex_t g_log_mu = PTHREAD_MUTEX_INITIALIZER;
            static pthread_once_t g_once = PTHREAD_ONCE_INIT;

            static void open_log(void) {
                g_log = fopen("/tmp/w3-writes.log", "a");
                if (g_log) {
                    setvbuf(g_log, NULL, _IOLBF, 0);
                    fprintf(g_log, "# open_log pid=%d\n", (int)getpid());
                }
            }

            static uint64_t now_ns(void) {
                struct timeval tv;
                gettimeofday(&tv, NULL);
                return (uint64_t)tv.tv_sec * 1000000000ull
                     + (uint64_t)tv.tv_usec * 1000ull;
            }

            extern int __xojit_executor_write_mem(void *addr, const void *bytes, uint64_t len);
            extern int __xojit_executor_run_program_on_main_thread(void *fn, void *args);
            extern int __xojit_executor_run_program_wrapper(void *fn, void *args);
            extern int __xojit_run_wrapper(void *fn, void *args);

            static int my_write_mem(void *addr, const void *bytes, uint64_t len) {
                pthread_once(&g_once, open_log);
                pthread_mutex_lock(&g_log_mu);
                if (g_log) {
                    fprintf(g_log, "%llu\twrite_mem\taddr=%p\tlen=%llu\ttid=%p\n",
                            (unsigned long long)now_ns(),
                            addr, (unsigned long long)len,
                            (void *)pthread_self());
                }
                pthread_mutex_unlock(&g_log_mu);
                return __xojit_executor_write_mem(addr, bytes, len);
            }

            static int my_run_program_main(void *fn, void *args) {
                pthread_once(&g_once, open_log);
                pthread_mutex_lock(&g_log_mu);
                if (g_log) {
                    fprintf(g_log, "%llu\trun_program_on_main_thread\tfn=%p\ttid=%p\n",
                            (unsigned long long)now_ns(),
                            fn, (void *)pthread_self());
                }
                pthread_mutex_unlock(&g_log_mu);
                return __xojit_executor_run_program_on_main_thread(fn, args);
            }

            static int my_run_program_wrapper(void *fn, void *args) {
                pthread_once(&g_once, open_log);
                pthread_mutex_lock(&g_log_mu);
                if (g_log) {
                    fprintf(g_log, "%llu\trun_program_wrapper\tfn=%p\ttid=%p\n",
                            (unsigned long long)now_ns(),
                            fn, (void *)pthread_self());
                }
                pthread_mutex_unlock(&g_log_mu);
                return __xojit_executor_run_program_wrapper(fn, args);
            }

            static int my_run_wrapper(void *fn, void *args) {
                pthread_once(&g_once, open_log);
                pthread_mutex_lock(&g_log_mu);
                if (g_log) {
                    fprintf(g_log, "%llu\trun_wrapper\tfn=%p\ttid=%p\n",
                            (unsigned long long)now_ns(),
                            fn, (void *)pthread_self());
                }
                pthread_mutex_unlock(&g_log_mu);
                return __xojit_run_wrapper(fn, args);
            }

            __attribute__((used))
            static const struct {
                const void *replacement;
                const void *replacee;
            } interposers[] __attribute__((section("__DATA,__interpose"))) = {
                { (const void *)&my_write_mem,
                  (const void *)&__xojit_executor_write_mem },
                { (const void *)&my_run_program_main,
                  (const void *)&__xojit_executor_run_program_on_main_thread },
                { (const void *)&my_run_program_wrapper,
                  (const void *)&__xojit_executor_run_program_wrapper },
                { (const void *)&my_run_wrapper,
                  (const void *)&__xojit_run_wrapper },
            };

            __attribute__((constructor))
            static void w3_interposer_init(void) {
                FILE *boot = fopen("/tmp/w3-interposer.log", "a");
                if (!boot) return;
                setvbuf(boot, NULL, _IOLBF, 0);

                char exe[1024]; uint32_t exelen = sizeof(exe);
                if (_NSGetExecutablePath(exe, &exelen) != 0) {
                    strncpy(exe, "?", sizeof(exe));
                }

                fprintf(boot, "%llu\tloaded\tpid=%d\texe=%s\n",
                        (unsigned long long)now_ns(),
                        (int)getpid(), exe);

                extern char **environ;
                if (environ) {
                    for (char **e = environ; *e; ++e) {
                        if (strncmp(*e, "DYLD_", 5) == 0) {
                            fprintf(boot, "%llu\tenv\t%s\n",
                                    (unsigned long long)now_ns(), *e);
                        }
                    }
                }
                fclose(boot);
            }
            """#
        let interposerHex = interposerC.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // dtrace exec/exit tracer (Q1/Q3/Q4/Q5 timing). SIP is off in this
        // VM, so the proc provider is available — the host-side W3 work
        // could not use it. Traces every preview-pipeline process spawn +
        // exit with a walltimestamp (ns since epoch, same clock as the
        // W3MARKER `logger` execs), so per edit we get: marker (save) →
        // swift-frontend exec/exit (compile, and whether it is one fresh
        // process per edit) → XCPreviewAgent exec (respawn). pr_psargs is
        // the (truncated) argv, enough to confirm the single -primary-file
        // shape in-VM; the full argv is the host W4 capture.
        let dtraceD = #"""
            #pragma D option quiet
            #pragma D option switchrate=10hz

            proc:::exec-success
            /execname == "swift-frontend" || execname == "swiftc" || execname == "swift-driver" || execname == "swift-plugin-server" || execname == "clang" || execname == "ld" || execname == "XCPreviewAgent" || execname == "previewsd" || execname == "logger"/
            {
                printf("%d EXEC %s pid=%d ppid=%d args=%s\n", walltimestamp, execname, pid, ppid, curpsinfo->pr_psargs);
            }

            proc:::exit
            /execname == "swift-frontend" || execname == "swiftc" || execname == "swift-driver" || execname == "swift-plugin-server" || execname == "clang" || execname == "ld" || execname == "XCPreviewAgent" || execname == "previewsd"/
            {
                printf("%d EXIT %s pid=%d\n", walltimestamp, execname, pid);
            }
            """#
        let dtraceHex = dtraceD.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // mach-o-add-dylib.c (LC_LOAD_DYLIB injector) and
        // mem-diff-helper.c (mach_vm_read snapshot/diff) are loaded
        // from the repo's `research/scripts/data/w3/` rather than
        // embedded inline. Both are ~150-250 LOC of C — too much to
        // duplicate as Swift raw strings without churn. `#filePath`
        // resolves to this source file's absolute path; the data dir
        // is at a known fixed relative location. If the files are
        // missing the deployed shell-script will emit a clear error
        // because the hex string will start with `#error`.
        let dataW3Dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()  // vz/
            .deletingLastPathComponent()  // Sources/
            .deletingLastPathComponent()  // vm/
            .deletingLastPathComponent()  // research/
            .appendingPathComponent("scripts/data/w3", isDirectory: true)
        let machoAddDylibC = (try? String(
            contentsOf: dataW3Dir.appendingPathComponent("mach-o-add-dylib.c"),
            encoding: .utf8))
            ?? "#error \"mach-o-add-dylib.c missing at \(dataW3Dir.path)\"\n"
        let memDiffHelperC = (try? String(
            contentsOf: dataW3Dir.appendingPathComponent("mem-diff-helper.c"),
            encoding: .utf8))
            ?? "#error \"mem-diff-helper.c missing at \(dataW3Dir.path)\"\n"
        let machoAddDylibHex = machoAddDylibC.utf8
            .map { String(format: "%02x", $0) }
            .joined()
        let memDiffHelperHex = memDiffHelperC.utf8
            .map { String(format: "%02x", $0) }
            .joined()

        // The `vz ssh` subcommand joins remoteCommand args with
        // a single space and hands the result to `ssh ... user@host
        // <command>`. We pass the entire remote command as ONE
        // argument (the no-`--` form) so vz's
        // ArgumentParser captures it cleanly as a single-element
        // remoteCommand array. The single-argument form with embedded
        // shell-escaped quotes is what works empirically (`--` form
        // confuses /usr/bin/ssh's argv parsing).
        func remote(_ shellCommand: String) -> String {
            // Escape any single quotes inside the command so we can
            // wrap the whole thing in single quotes for vz's
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
            .type("vz"),
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

            // Clean any stale Xcode/agent state so the launchctl-setenv
            // below applies to a fresh process tree.
            .hostShell(
                command: remote("pkill -9 -f XCPreviewAgent 2>/dev/null; pkill -9 -f Xcode 2>/dev/null; sleep 2; pgrep -f Xcode || echo XCODE_CLEAN"),
                label: "kill stale Xcode/agent",
                expectContains: "XCODE_CLEAN"),

            // Deploy the interposer C source, build the dylib via clang
            // (Xcode's toolchain is on PATH after xcode-select pointed at
            // /Applications/Xcode.app), and ad-hoc-codesign it. arm64 is
            // what we build — dyld will happily load arm64 dylibs into
            // arm64e processes (this is the standard third-party-dylib
            // case). arm64e on user binaries requires special signing
            // we don't have, and isn't necessary for interposing.
            .hostShell(
                command: remote("printf %s \(interposerHex) | xxd -r -p > /tmp/w3-interposer.c && wc -l /tmp/w3-interposer.c && echo INTERPOSER_SRC_DEPLOYED"),
                label: "deploy interposer.c",
                expectContains: "INTERPOSER_SRC_DEPLOYED"),
            // -undefined dynamic_lookup: the four `__xojit_executor_*`
            // symbols only exist at runtime in the agent (XOJITExecutor
            // lives in dyld_shared_cache; the framework headers aren't
            // exposed to the SDK). Defer resolution to dyld at load
            // time. -install_name ensures the dylib's LC_ID_DYLIB
            // matches the LC_LOAD_DYLIB path we add to the agent
            // below (mismatch is tolerated on AMFI-off but cleaner
            // matched).
            //
            // -arch arm64 -arch arm64e builds a fat dylib so it loads
            // into BOTH the agent's arm64e slice (which macOS-on-
            // Apple-Silicon picks first) and the arm64 fallback slice
            // (which dyld uses if it rejects the arm64e slice for any
            // reason — our ad-hoc re-codesign of the agent may trip
            // arm64e validation). A first run with -arch arm64 only
            // failed with dyld errors "have 'arm64', need 'arm64e'".
            .hostShell(
                command: remote("clang -dynamiclib -arch arm64 -arch arm64e -Wall -Wno-unused-function -O0 -g -undefined dynamic_lookup -install_name /tmp/w3-interposer.dylib -o /tmp/w3-interposer.dylib /tmp/w3-interposer.c 2>&1 && codesign --force --sign - /tmp/w3-interposer.dylib && file /tmp/w3-interposer.dylib && lipo -archs /tmp/w3-interposer.dylib && echo INTERPOSER_BUILT"),
                label: "build + ad-hoc sign interposer dylib (fat)",
                expectContains: "INTERPOSER_BUILT"),

            // Deploy + build the LC_LOAD_DYLIB injector. The tool
            // appends an LC_LOAD_DYLIB load command to the agent
            // binary's arm64e slice. ~150 LOC of pure C, no deps.
            .hostShell(
                command: remote("printf %s \(machoAddDylibHex) | xxd -r -p > /tmp/mach-o-add-dylib.c && wc -l /tmp/mach-o-add-dylib.c && echo MACHO_TOOL_SRC_DEPLOYED"),
                label: "deploy mach-o-add-dylib.c",
                expectContains: "MACHO_TOOL_SRC_DEPLOYED"),
            .hostShell(
                command: remote("clang -O2 -Wall -o /tmp/mach-o-add-dylib /tmp/mach-o-add-dylib.c 2>&1 && file /tmp/mach-o-add-dylib && echo MACHO_TOOL_BUILT"),
                label: "build mach-o-add-dylib",
                expectContains: "MACHO_TOOL_BUILT"),

            // Deploy + build the mach_vm_read snapshot/diff helper —
            // second-source capture in parallel with the interposer.
            // Uses task_for_pid against the agent's get-task-allow
            // entitlement; mach_vm_read_overwrite is non-invasive
            // (target keeps running) so no heartbeat timeout fires.
            .hostShell(
                command: remote("printf %s \(memDiffHelperHex) | xxd -r -p > /tmp/mem-diff-helper.c && wc -l /tmp/mem-diff-helper.c && echo MEMDIFF_SRC_DEPLOYED"),
                label: "deploy mem-diff-helper.c",
                expectContains: "MEMDIFF_SRC_DEPLOYED"),
            .hostShell(
                command: remote("clang -O2 -Wall -o /tmp/mem-diff-helper /tmp/mem-diff-helper.c 2>&1 && file /tmp/mem-diff-helper && echo MEMDIFF_BUILT"),
                label: "build mem-diff-helper",
                expectContains: "MEMDIFF_BUILT"),

            // Patch the agent binary in-place. /Applications/Xcode.app
            // is outside SSV — writable with sudo. The path:
            //   1. Write a hardcoded entitlements plist (the agent's
            //      original entitlement is just get-task-allow=true,
            //      captured by `codesign -d --entitlements` in a
            //      prior session). Hardcoding sidesteps the wrapped
            //      CMS blob format that codesign-display emits but
            //      codesign-sign can't read back.
            //   2. Backup, then run mach-o-add-dylib in-place.
            //   3. Re-codesign ad-hoc with the entitlements,
            //      preserving get-task-allow so mem-diff-helper +
            //      anything else relying on task-port access still
            //      works.
            //   4. Verify by `otool -L` lists the interposer path.
            //
            // Split into multiple hostShell steps so each failure is
            // pinpointed.
            .hostShell(
                command: remote("cat > /tmp/agent.entitlements.xml << 'XMLEOF'\n<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict>\n    <key>com.apple.security.get-task-allow</key>\n    <true/>\n</dict>\n</plist>\nXMLEOF\nwc -l /tmp/agent.entitlements.xml && echo ENT_WRITTEN"),
                label: "write hardcoded entitlements plist",
                expectContains: "ENT_WRITTEN"),
            .hostShell(
                command: remote("AGENT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent; echo vz | sudo -S cp \"$AGENT\" /tmp/XCPreviewAgent.bak && ls -la /tmp/XCPreviewAgent.bak && echo AGENT_BACKED_UP"),
                label: "backup XCPreviewAgent",
                expectContains: "AGENT_BACKED_UP"),
            .hostShell(
                command: remote("AGENT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent; echo vz | sudo -S /tmp/mach-o-add-dylib \"$AGENT\" /tmp/w3-interposer.dylib 2>&1 && echo AGENT_PATCHED_BYTES"),
                label: "append LC_LOAD_DYLIB to agent",
                expectContains: "AGENT_PATCHED_BYTES"),
            .hostShell(
                command: remote("AGENT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent; echo vz | sudo -S codesign --force --sign - --entitlements /tmp/agent.entitlements.xml \"$AGENT\" 2>&1 && echo vz | sudo -S codesign -d --verbose=2 \"$AGENT\" 2>&1 | head -5 && echo AGENT_CODESIGNED"),
                label: "ad-hoc re-codesign agent with entitlements",
                expectContains: "AGENT_CODESIGNED"),
            .hostShell(
                command: remote("AGENT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent; otool -L \"$AGENT\" | grep -F /tmp/w3-interposer.dylib && echo vz | sudo -S codesign -d --entitlements :- \"$AGENT\" 2>&1 | head -10 && echo VERIFIED_INTERPOSER_IN_LOAD_CMDS"),
                label: "verify interposer in load commands",
                expectContains: "VERIFIED_INTERPOSER_IN_LOAD_CMDS"),

            // Sanity test: does dyld actually load our interposer
            // dylib when DYLD_INSERT_LIBRARIES'd into a trivial
            // process? Tests the dylib's loadability independent of
            // the LC_LOAD_DYLIB injection path. /usr/bin/true is the
            // smallest possible target. After this runs, the
            // constructor should have written a "loaded" line to
            // /tmp/w3-interposer.log if the dylib is well-formed.
            .hostShell(
                command: remote("rm -f /tmp/w3-interposer.log; DYLD_INSERT_LIBRARIES=/tmp/w3-interposer.dylib /usr/bin/true 2>&1; echo '--- dylib loadability test result ---'; ls -la /tmp/w3-interposer.log 2>&1; cat /tmp/w3-interposer.log 2>&1; echo DYLIB_SANITY_DONE"),
                label: "sanity test interposer dylib loadability",
                expectContains: "DYLIB_SANITY_DONE"),

            // Capture the modified-agent's dyld trace by spawning it
            // ourselves with DYLD_PRINT_LIBRARIES + a short timeout.
            // The agent will hang waiting for XPC, but dyld's
            // library-load messages fire BEFORE that (early in
            // startup). Kills after 3s. The output will show whether
            // /tmp/w3-interposer.dylib is in the load list.
            .hostShell(
                command: remote("AGENT=/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent; (echo vz | sudo -S env DYLD_PRINT_LIBRARIES=1 \"$AGENT\" > /tmp/agent-dyld-trace.log 2>&1 &); TEST_PID=$!; sleep 3; echo vz | sudo -S pkill -9 -f XCPreviewAgent 2>/dev/null; sleep 1; echo '--- /tmp/agent-dyld-trace.log head ---'; head -100 /tmp/agent-dyld-trace.log; echo '--- search for /tmp/w3-interposer.dylib ---'; grep -F 'w3-interposer' /tmp/agent-dyld-trace.log || echo INTERPOSER_NOT_IN_DYLD_TRACE; echo DYLD_TRACE_DONE"),
                label: "trace modified agent's dyld loads",
                expectContains: "DYLD_TRACE_DONE"),

            // Clean prior run's logs so we capture a fresh trace.
            .hostShell(
                command: remote("rm -f /tmp/w3-writes.log /tmp/w3-interposer.log /tmp/w3-mem-before.snap /tmp/w3-mem-after.snap /tmp/w3-mem-diff.txt && touch /tmp/w3-writes.log /tmp/w3-interposer.log && chmod 666 /tmp/w3-writes.log /tmp/w3-interposer.log && echo LOGS_RESET"),
                label: "reset interposer + mem-diff log files",
                expectContains: "LOGS_RESET"),

            // Inject the interposer into every new process launchd
            // spawns in this user session. `launchctl setenv` writes
            // into launchd's user-session env; any process subsequently
            // started by launchd (incl. Xcode via LaunchServices) and
            // its descendants (incl. previewsd and XCPreviewAgent)
            // inherits these values. DYLD_FORCE_FLAT_NAMESPACE=1
            // forces dyld to consult the __interpose table on every
            // call, including intra-XOJITExecutor calls that would
            // otherwise be routed by two-level namespace binding past
            // our entry. The chained semantics here: previewsd is
            // expected to call setenv() itself to add
            // PreviewsInjection.framework to DYLD_INSERT_LIBRARIES; if
            // it APPENDS to the existing value our dylib stays; if it
            // REPLACES, only PreviewsInjection ends up loaded — in
            // which case `/tmp/w3-interposer.log` stays empty and we
            // can switch to `dyld_dynamic_interpose` from a
            // constructor (the handoff doc's fallback path).
            .hostShell(
                command: remote("launchctl setenv DYLD_INSERT_LIBRARIES /tmp/w3-interposer.dylib && launchctl setenv DYLD_FORCE_FLAT_NAMESPACE 1 && launchctl getenv DYLD_INSERT_LIBRARIES && launchctl getenv DYLD_FORCE_FLAT_NAMESPACE && echo SETENV_OK"),
                label: "launchctl setenv DYLD_INSERT_LIBRARIES",
                expectContains: "SETENV_OK"),

            // Rebuild the test package as a LIBRARY target (no @main,
            // no main.swift top-level conflict). The previous structure
            // had `@main struct HelloApp: App` in a file named
            // main.swift, which Swift rejects (\"main attribute cannot
            // be used in a module that contains top-level code\") and
            // the resulting build error stops preview rendering from
            // ever activating XCPreviewAgent. Library target with a
            // single ContentView.swift containing only the View type
            // and the #Preview block compiles cleanly.
            // Multi-file library target. ContentView pulls a literal
            // from Model.swift's `Greeter`, so a Model.swift edit IS a
            // cross-file edit affecting the rendered body.
            .hostShell(
                command: remote("rm -rf /Users/admin/HelloPreview && mkdir -p /Users/admin/HelloPreview/Sources/HelloPreview && cat > /Users/admin/HelloPreview/Package.swift << 'PKEOF'\n// swift-tools-version: 6.0\nimport PackageDescription\n\nlet package = Package(\n    name: \"HelloPreview\",\n    platforms: [.macOS(.v14)],\n    targets: [.target(name: \"HelloPreview\")]\n)\nPKEOF\ncat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix).font(.title)\n            Text(\"World\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 120)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ncat > /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift << 'MDEOF'\npublic struct Greeter {\n    public init() {}\n    public var prefix: String = \"Hello\"\n}\nMDEOF\nls -la /Users/admin/HelloPreview/Sources/HelloPreview/ && echo PKG_REBUILT"),
                label: "rebuild test package as multi-file library",
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

            // Open Package.swift then ContentView.swift in Xcode.
            //
            // NOTE: this preset's `launchctl setenv DYLD_INSERT_LIBRARIES`
            // above does NOT propagate into Xcode (let alone the agent).
            // Three barriers were confirmed empirically across runs:
            //   1. `launchctl setenv` from the SSH session lands in
            //      the SSH bootstrap, not in admin's GUI launchd
            //      session. `launchctl asuser 501 /bin/bash -lc 'echo
            //      $DYLD_INSERT_LIBRARIES'` returns empty even after
            //      the setenv step succeeded.
            //   2. `open -a Xcode.app` goes through LaunchServices,
            //      which strips DYLD_* env vars on the way to launchd.
            //   3. previewsd reconstructs DYLD_INSERT_LIBRARIES for
            //      the agent from a hardcoded 5-entry list
            //      (libLogRedirect, libPlaygrounds,
            //      libLiveExecutionResultsLogger,
            //      LiveExecutionResultsProbe, PreviewsInjection). Even
            //      if we got our dylib into Xcode's env, previewsd
            //      drops it.
            // Bypassing barrier (2) via `launchctl asuser 501 env
            // DYLD_INSERT_LIBRARIES=… /Applications/Xcode.app/Contents/MacOS/Xcode`
            // was tried and produced an Xcode that never spawned the
            // agent (the preview pipeline depends on LaunchServices
            // session context that direct-exec lacks).
            //
            // Conclusion: the DYLD_INSERT_LIBRARIES path is
            // architecturally blocked. The fallback is binary
            // modification — either appending an LC_LOAD_DYLIB to the
            // agent binary, or wrapping libLogRedirect.dylib inside
            // Xcode.app with a shim that loads both itself and the
            // interposer. See `handoff.md` for the full plan.
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

            // Start the dtrace exec/exit tracer AFTER the agent is up.
            // Started before canvas-open it added per-exec overhead during
            // Xcode's heavy startup and the agent never spawned within
            // previewsd's window (two attempts failed at AGENT_UP). We
            // therefore forgo the cold first-compile/first-JIT-link and
            // capture all 12 edits' compile + respawn timing, which is the
            // core of Q1/Q5 (and per-edit Q3/Q4). Deploy via hex+xxd, then
            // run under sudo detached (full fd redirection so SSH returns).
            .hostShell(
                command: remote("printf %s \(dtraceHex) | xxd -r -p > /tmp/q1-trace.d && wc -l /tmp/q1-trace.d && echo DTRACE_SRC_DEPLOYED"),
                label: "deploy dtrace script",
                expectContains: "DTRACE_SRC_DEPLOYED"),
            .hostShell(
                command: remote("echo vz | sudo -S sh -c 'nohup dtrace -q -s /tmp/q1-trace.d -o /tmp/q1-dtrace.log > /tmp/q1-dtrace.out 2>/tmp/q1-dtrace.err < /dev/null & echo $! > /tmp/q1-dtrace.pid'; sleep 5; pgrep -x dtrace > /dev/null && echo DTRACE_OK || { echo DTRACE_FAILED; cat /tmp/q1-dtrace.err 2>/dev/null; }"),
                label: "start dtrace exec/exit tracer",
                expectContains: "DTRACE_OK"),

            // Diagnostic: did our interposer dylib actually load into
            // the agent? The constructor in interposer.c appends a
            // `loaded pid=… exe=…` line to /tmp/w3-interposer.log when
            // dyld processes the dylib. If this file has a line whose
            // exe path ends in `XCPreviewAgent`, the interposer is
            // resident in the agent's address space and we expect the
            // hot-reload to drive write_mem hits into /tmp/w3-writes.log.
            // If the file is empty (or only has `loaded` lines from
            // Xcode / previewsd but not the agent), previewsd is
            // replacing DYLD_INSERT_LIBRARIES on the agent spawn and
            // we need the dyld_dynamic_interpose fallback per the
            // handoff doc.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AGENT_PID=$AGENT_PID; echo '--- agent env (DYLD_*) ---'; ps -E -ww -p $AGENT_PID | tr ' ' '\\n' | grep '^DYLD_' || echo '(no DYLD_* in env)'; echo '--- /tmp/w3-interposer.log ---'; cat /tmp/w3-interposer.log; echo '--- agent constructor presence ---'; grep -F XCPreviewAgent /tmp/w3-interposer.log && echo INTERPOSER_IN_AGENT || echo INTERPOSER_NOT_IN_AGENT"),
                label: "verify interposer loaded in agent"),
            .screenshot(label: "05-interposer-check"),

            // Multi-edit sequence. Each edit fires a hot-reload; we
            // snapshot the agent's writable regions before + after and
            // diff. The interposer log accumulates across all edits, so
            // we can correlate timestamps with sed-step labels.
            //
            // Edit kinds tested, in order of expected ABI impact (low
            // → high):
            //   1. body-literal-same-file: change a string literal in
            //      ContentView.swift.
            //   2. body-literal-cross-file: change Greeter.prefix in
            //      Model.swift; ContentView reads it via greeter.prefix
            //      so the rendered body changes without modifying
            //      ContentView itself.
            //   3. add-method: insert a new method into ContentView
            //      before `var body`. Doesn't change body's signature
            //      but adds an entry to the type's method table.
            //   4. add-state: insert an `@State` stored property into
            //      ContentView. Changes the View's stored layout —
            //      structural ABI impact.
            //
            // Goal: see whether any of these triggers
            // `__xojit_executor_write_mem`, or whether all of them
            // follow the body-literal pattern (run_program_* +
            // respawn-only). Inversely: also captures whether
            // PreviewsInjection's JIT-link entry points fire per edit.

            // Edit 1: body-literal-same-file (World → Earth).
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E1_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e1.snap 2>&1; echo SNAP_BEFORE_E1_OK"),
                label: "mem-diff snapshot before edit 1",
                expectContains: "SNAP_BEFORE_E1_OK"),
            .hostShell(
                command: remote("sed -i.bak s/World/Earth/g /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && grep Earth /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e1 body-literal-same-file saved\" && echo EDIT1_OK"),
                label: "edit 1: body-literal-same-file (World→Earth)",
                expectContains: "EDIT1_OK"),
            .log("waiting 30s for edit-1 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E1_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e1.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e1.snap /tmp/w3-mem-after-e1.snap /tmp/w3-mem-diff-e1.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e1.txt && wc -l /tmp/w3-mem-diff-e1.txt; echo SNAP_AFTER_E1_OK"),
                label: "mem-diff snapshot after edit 1 + diff",
                expectContains: "SNAP_AFTER_E1_OK"),
            .screenshot(label: "06a-after-edit-1"),

            // Edit 2: body-literal-cross-file (Hello → Howdy in Model.swift).
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E2_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e2.snap 2>&1; echo SNAP_BEFORE_E2_OK"),
                label: "mem-diff snapshot before edit 2",
                expectContains: "SNAP_BEFORE_E2_OK"),
            .hostShell(
                command: remote("sed -i.bak s/Hello/Howdy/g /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift && grep Howdy /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift > /dev/null && logger \"W3MARKER e2 body-literal-cross-file saved\" && echo EDIT2_OK"),
                label: "edit 2: body-literal-cross-file (Hello→Howdy in Model.swift)",
                expectContains: "EDIT2_OK"),
            .log("waiting 30s for edit-2 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E2_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e2.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e2.snap /tmp/w3-mem-after-e2.snap /tmp/w3-mem-diff-e2.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e2.txt && wc -l /tmp/w3-mem-diff-e2.txt; echo SNAP_AFTER_E2_OK"),
                label: "mem-diff snapshot after edit 2 + diff",
                expectContains: "SNAP_AFTER_E2_OK"),
            .screenshot(label: "06b-after-edit-2"),

            // Edit 3: add-method. Inserts a new method into
            // ContentView via cat-overwrite (simpler than sed-insert
            // with multi-line content). Preserves edits 1+2 so the
            // edited Model + Earth literal stay live.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E3_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e3.snap 2>&1; echo SNAP_BEFORE_E3_OK"),
                label: "mem-diff snapshot before edit 3",
                expectContains: "SNAP_BEFORE_E3_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    func decorate(_ s: String) -> String { s.uppercased() }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 120)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ngrep decorate /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e3 add-method saved\" && echo EDIT3_OK"),
                label: "edit 3: add-method (new func decorate)",
                expectContains: "EDIT3_OK"),
            .log("waiting 30s for edit-3 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E3_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e3.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e3.snap /tmp/w3-mem-after-e3.snap /tmp/w3-mem-diff-e3.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e3.txt && wc -l /tmp/w3-mem-diff-e3.txt; echo SNAP_AFTER_E3_OK"),
                label: "mem-diff snapshot after edit 3 + diff",
                expectContains: "SNAP_AFTER_E3_OK"),
            .screenshot(label: "06c-after-edit-3"),

            // Edit 4: add-state. Adds an `@State` stored property to
            // ContentView. Changes the View's stored layout — the
            // structural-ABI case most likely to require something
            // other than respawn-only.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E4_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e4.snap 2>&1; echo SNAP_BEFORE_E4_OK"),
                label: "mem-diff snapshot before edit 4",
                expectContains: "SNAP_BEFORE_E4_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    @State private var counter: Int = 0\n    func decorate(_ s: String) -> String { s.uppercased() }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n            Text(\"counter=\\(counter)\")\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ngrep '@State' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e4 add-state saved\" && echo EDIT4_OK"),
                label: "edit 4: add-state (@State property)",
                expectContains: "EDIT4_OK"),
            .log("waiting 30s for edit-4 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E4_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e4.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e4.snap /tmp/w3-mem-after-e4.snap /tmp/w3-mem-diff-e4.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e4.txt && wc -l /tmp/w3-mem-diff-e4.txt; echo SNAP_AFTER_E4_OK"),
                label: "mem-diff snapshot after edit 4 + diff",
                expectContains: "SNAP_AFTER_E4_OK"),
            .screenshot(label: "06d-after-edit-4"),

            // Edit 5: remove-stored-property. Removes `@State counter`
            // (and the Text that reads it). ABI SHRINKS — the view's
            // stored-property count goes down. Test: does this still
            // respawn, or does it crash the agent (ABI mismatch with
            // pre-existing JIT'd code)?
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E5_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e5.snap 2>&1; echo SNAP_BEFORE_E5_OK"),
                label: "mem-diff snapshot before edit 5",
                expectContains: "SNAP_BEFORE_E5_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    func decorate(_ s: String) -> String { s.uppercased() }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\n! grep '@State' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e5 remove-stored-property saved\" && echo EDIT5_OK"),
                label: "edit 5: remove-stored-property (drop @State counter)",
                expectContains: "EDIT5_OK"),
            .log("waiting 30s for edit-5 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E5_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e5.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e5.snap /tmp/w3-mem-after-e5.snap /tmp/w3-mem-diff-e5.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e5.txt && wc -l /tmp/w3-mem-diff-e5.txt; echo SNAP_AFTER_E5_OK"),
                label: "mem-diff snapshot after edit 5 + diff",
                expectContains: "SNAP_AFTER_E5_OK"),
            .screenshot(label: "06e-after-edit-5"),

            // Edit 6: function-signature change. `decorate(_:)` →
            // `decorate(_:suffix:)` with a new String param + default
            // value. Changes the function's Swift mangled name +
            // witness signature.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E6_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e6.snap 2>&1; echo SNAP_BEFORE_E6_OK"),
                label: "mem-diff snapshot before edit 6",
                expectContains: "SNAP_BEFORE_E6_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    func decorate(_ s: String, suffix: String = \"!\") -> String { s.uppercased() + suffix }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ngrep 'suffix: String' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e6 function-sig-change saved\" && echo EDIT6_OK"),
                label: "edit 6: function-sig change (decorate adds suffix param)",
                expectContains: "EDIT6_OK"),
            .log("waiting 30s for edit-6 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E6_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e6.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e6.snap /tmp/w3-mem-after-e6.snap /tmp/w3-mem-diff-e6.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e6.txt && wc -l /tmp/w3-mem-diff-e6.txt; echo SNAP_AFTER_E6_OK"),
                label: "mem-diff snapshot after edit 6 + diff",
                expectContains: "SNAP_AFTER_E6_OK"),
            .screenshot(label: "06f-after-edit-6"),

            // Edit 7: new-file-with-new-type. Adds Extras.swift with
            // a new public struct `Decoration`. ContentView gains a
            // reference to it. Cross-image symbol introduction.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E7_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e7.snap 2>&1; echo SNAP_BEFORE_E7_OK"),
                label: "mem-diff snapshot before edit 7",
                expectContains: "SNAP_BEFORE_E7_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/Extras.swift << 'EXEOF'\npublic struct Decoration {\n    public init() {}\n    public var symbol: String = \"*\"\n}\nEXEOF\ncat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    let decoration = Decoration()\n    func decorate(_ s: String, suffix: String = \"!\") -> String { s.uppercased() + suffix }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix + decoration.symbol).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ntest -f /Users/admin/HelloPreview/Sources/HelloPreview/Extras.swift && grep Decoration /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e7 new-file-new-type saved\" && echo EDIT7_OK"),
                label: "edit 7: new file Extras.swift + use it in ContentView",
                expectContains: "EDIT7_OK"),
            .log("waiting 30s for edit-7 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E7_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e7.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e7.snap /tmp/w3-mem-after-e7.snap /tmp/w3-mem-diff-e7.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e7.txt && wc -l /tmp/w3-mem-diff-e7.txt; echo SNAP_AFTER_E7_OK"),
                label: "mem-diff snapshot after edit 7 + diff",
                expectContains: "SNAP_AFTER_E7_OK"),
            .screenshot(label: "06g-after-edit-7"),

            // Edit 8: conformance addition. Adds `extension Greeter:
            // CustomStringConvertible` in Model.swift. The protocol
            // witness table for Greeter:CustomStringConvertible is a
            // NEW witness install. Tests whether protocol-conformance
            // additions go through the same respawn path.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E8_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e8.snap 2>&1; echo SNAP_BEFORE_E8_OK"),
                label: "mem-diff snapshot before edit 8",
                expectContains: "SNAP_BEFORE_E8_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift << 'MDEOF'\npublic struct Greeter {\n    public init() {}\n    public var prefix: String = \"Howdy\"\n}\n\nextension Greeter: CustomStringConvertible {\n    public var description: String { prefix }\n}\nMDEOF\ngrep CustomStringConvertible /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift > /dev/null && logger \"W3MARKER e8 conformance-addition saved\" && echo EDIT8_OK"),
                label: "edit 8: conformance addition (Greeter: CustomStringConvertible)",
                expectContains: "EDIT8_OK"),
            .log("waiting 30s for edit-8 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E8_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e8.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e8.snap /tmp/w3-mem-after-e8.snap /tmp/w3-mem-diff-e8.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e8.txt && wc -l /tmp/w3-mem-diff-e8.txt; echo SNAP_AFTER_E8_OK"),
                label: "mem-diff snapshot after edit 8 + diff",
                expectContains: "SNAP_AFTER_E8_OK"),
            .screenshot(label: "06h-after-edit-8"),

            // Edit 9: whitespace-only. Adds a blank line to
            // ContentView.swift; no semantic change. Does Apple's
            // file-watcher short-circuit "no real change" edits, or
            // does it respawn every time?
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E9_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e9.snap 2>&1; echo SNAP_BEFORE_E9_OK"),
                label: "mem-diff snapshot before edit 9",
                expectContains: "SNAP_BEFORE_E9_OK"),
            .hostShell(
                command: remote("sed -i.bak '/^public struct ContentView/i\\\n// w3-whitespace-edit-marker\n' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && grep w3-whitespace-edit-marker /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e9 whitespace-only saved\" && echo EDIT9_OK"),
                label: "edit 9: whitespace-only (insert comment line)",
                expectContains: "EDIT9_OK"),
            .log("waiting 30s for edit-9 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E9_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e9.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e9.snap /tmp/w3-mem-after-e9.snap /tmp/w3-mem-diff-e9.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e9.txt && wc -l /tmp/w3-mem-diff-e9.txt; echo SNAP_AFTER_E9_OK"),
                label: "mem-diff snapshot after edit 9 + diff",
                expectContains: "SNAP_AFTER_E9_OK"),
            .screenshot(label: "06i-after-edit-9"),

            // Edit 10: generic-parameter add. Turns `decorate` into a
            // generic over `T: CustomStringConvertible`. Most
            // demanding ABI mutation: changes the function's
            // generic-parameter-list, mangled name, and the witness
            // signature.
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E10_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e10.snap 2>&1; echo SNAP_BEFORE_E10_OK"),
                label: "mem-diff snapshot before edit 10",
                expectContains: "SNAP_BEFORE_E10_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    let decoration = Decoration()\n    func decorate<T: CustomStringConvertible>(_ s: T, suffix: String = \"!\") -> String { \"\\(s)\".uppercased() + suffix }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix + decoration.symbol).font(.title)\n            Text(\"Earth\").foregroundColor(.blue)\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ngrep '<T: CustomStringConvertible>' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && logger \"W3MARKER e10 generic-parameter-add saved\" && echo EDIT10_OK"),
                label: "edit 10: generic-parameter add (decorate becomes generic)",
                expectContains: "EDIT10_OK"),
            .log("waiting 30s for edit-10 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E10_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e10.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e10.snap /tmp/w3-mem-after-e10.snap /tmp/w3-mem-diff-e10.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e10.txt && wc -l /tmp/w3-mem-diff-e10.txt; echo SNAP_AFTER_E10_OK"),
                label: "mem-diff snapshot after edit 10 + diff",
                expectContains: "SNAP_AFTER_E10_OK"),
            .screenshot(label: "06j-after-edit-10"),

            // Edit 11: simultaneous two-file edit. Writes to
            // ContentView.swift AND Model.swift in one shell
            // (effectively atomic from the watcher's POV). Does
            // previewsd coalesce these into ONE respawn or two?
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E11_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e11.snap 2>&1; echo SNAP_BEFORE_E11_OK"),
                label: "mem-diff snapshot before edit 11",
                expectContains: "SNAP_BEFORE_E11_OK"),
            .hostShell(
                command: remote("cat > /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift << 'SWEOF'\nimport SwiftUI\n\npublic struct ContentView: View {\n    public init() {}\n    let greeter = Greeter()\n    let decoration = Decoration()\n    func decorate<T: CustomStringConvertible>(_ s: T, suffix: String = \"!\") -> String { \"\\(s)\".uppercased() + suffix }\n    public var body: some View {\n        VStack {\n            Text(greeter.prefix + decoration.symbol).font(.title)\n            Text(\"Mars\").foregroundColor(.purple)\n        }\n        .padding()\n        .frame(width: 200, height: 160)\n    }\n}\n\n#Preview {\n    ContentView()\n}\nSWEOF\ncat > /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift << 'MDEOF'\npublic struct Greeter {\n    public init() {}\n    public var prefix: String = \"Aloha\"\n}\n\nextension Greeter: CustomStringConvertible {\n    public var description: String { prefix }\n}\nMDEOF\ngrep Mars /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift > /dev/null && grep Aloha /Users/admin/HelloPreview/Sources/HelloPreview/Model.swift > /dev/null && logger \"W3MARKER e11 simultaneous-two-file saved\" && echo EDIT11_OK"),
                label: "edit 11: simultaneous two-file (ContentView + Model)",
                expectContains: "EDIT11_OK"),
            .log("waiting 30s for edit-11 hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E11_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e11.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e11.snap /tmp/w3-mem-after-e11.snap /tmp/w3-mem-diff-e11.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e11.txt && wc -l /tmp/w3-mem-diff-e11.txt; echo SNAP_AFTER_E11_OK"),
                label: "mem-diff snapshot after edit 11 + diff",
                expectContains: "SNAP_AFTER_E11_OK"),
            .screenshot(label: "06k-after-edit-11"),

            // Edit 12: touch without content change. Updates mtime
            // but file contents byte-identical. Does the file-watcher
            // trigger a respawn anyway, or does it dedupe based on
            // content?
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo BEFORE_E12_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-before-e12.snap 2>&1; echo SNAP_BEFORE_E12_OK"),
                label: "mem-diff snapshot before edit 12",
                expectContains: "SNAP_BEFORE_E12_OK"),
            .hostShell(
                command: remote("touch /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && stat -f '%m %N' /Users/admin/HelloPreview/Sources/HelloPreview/ContentView.swift && logger \"W3MARKER e12 touch-no-change saved\" && echo EDIT12_OK"),
                label: "edit 12: touch-without-content-change",
                expectContains: "EDIT12_OK"),
            .log("waiting 30s for edit-12 (maybe) hot-reload"),
            .wait(seconds: 30),
            .hostShell(
                command: remote("AGENT_PID=\"\"; for _i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do AP=$(pgrep -n -f XCPreviewAgent); if [ -n \"$AP\" ]; then AGENT_PID=$AP; break; fi; sleep 2; done; echo AFTER_E12_PID=$AGENT_PID; echo vz | sudo -S /tmp/mem-diff-helper snapshot $AGENT_PID /tmp/w3-mem-after-e12.snap 2>&1 && echo vz | sudo -S /tmp/mem-diff-helper diff /tmp/w3-mem-before-e12.snap /tmp/w3-mem-after-e12.snap /tmp/w3-mem-diff-e12.txt 2>&1 && echo vz | sudo -S chmod 644 /tmp/w3-mem-diff-e12.txt && wc -l /tmp/w3-mem-diff-e12.txt; echo SNAP_AFTER_E12_OK"),
                label: "mem-diff snapshot after edit 12 + diff",
                expectContains: "SNAP_AFTER_E12_OK"),
            .screenshot(label: "06l-after-edit-12"),

            // Peek the accumulated interposer trace. Stats now span
            // ALL 12 edits.
            .hostShell(
                command: remote("echo '--- /tmp/w3-writes.log ---'; wc -l /tmp/w3-writes.log; echo '--- write_mem hits (if any) ---'; grep -c write_mem /tmp/w3-writes.log || echo 0; echo '--- pi_jit_link hits ---'; grep -c pi_jit_link /tmp/w3-writes.log || echo 0; echo '--- xpc_send count ---'; grep -c 'xpc_send\\b' /tmp/w3-writes.log || echo 0; echo '--- xpc_recv count ---'; grep -c xpc_recv /tmp/w3-writes.log || echo 0; echo '--- xpc_set_event_handler count ---'; grep -c xpc_set_event_handler /tmp/w3-writes.log || echo 0; echo '--- xpc_get_value count ---'; grep -c xpc_get_value /tmp/w3-writes.log || echo 0; echo '--- dyld_add_image count ---'; grep -c dyld_add_image /tmp/w3-writes.log || echo 0; echo '--- run_program count ---'; grep -c run_program /tmp/w3-writes.log || echo 0; echo '--- open_log markers (one per agent process) ---'; grep -c open_log /tmp/w3-writes.log || echo 0"),
                label: "peek accumulated trace stats"),

            // Stop the dtrace tracer and flush. Kill by saved PID, then a
            // pkill fallback. Report line counts so a failed capture is
            // obvious before retrieval: total lines, swift-frontend execs
            // (per-edit compiler processes), XCPreviewAgent execs
            // (respawns), and the logger markers (save anchors).
            .hostShell(
                command: remote("echo vz | sudo -S kill \"$(cat /tmp/q1-dtrace.pid)\" 2>/dev/null; sleep 2; echo vz | sudo -S pkill -x dtrace 2>/dev/null; sleep 1; echo vz | sudo -S chmod 644 /tmp/q1-dtrace.log; echo '--- dtrace lines ---'; wc -l /tmp/q1-dtrace.log; echo '--- swift-frontend EXEC ---'; grep -c 'EXEC swift-frontend' /tmp/q1-dtrace.log || echo 0; echo '--- XCPreviewAgent EXEC ---'; grep -c 'EXEC XCPreviewAgent' /tmp/q1-dtrace.log || echo 0; echo '--- W3MARKER logger EXEC ---'; grep -c 'W3MARKER' /tmp/q1-dtrace.log || echo 0; echo DTRACE_STOPPED"),
                label: "stop dtrace tracer",
                expectContains: "DTRACE_STOPPED"),

            // Retrieve the dtrace trace FIRST — before the mem-diff /
            // interposer retrievals, which can fail (e.g. the new-file
            // edit produces no mem-diff) and abort the attempt. This is
            // the Q1/Q3/Q4/Q5 deliverable; it must reach the host even if
            // a later W3-apparatus retrieval throws.
            .hostShell(
                command: remote("cat /tmp/q1-dtrace.log") + " > \"\(outputDir)/q1-dtrace.txt\" && wc -l \"\(outputDir)/q1-dtrace.txt\"",
                label: "retrieve dtrace trace to host (priority)"),

            // Retrieve every captured artifact.
            .hostShell(
                command: remote("cat /tmp/w3-writes.log") + " > \"\(outputDir)/w3-writes.interposer.txt\" && wc -l \"\(outputDir)/w3-writes.interposer.txt\"",
                label: "retrieve interposer log to host"),
            .hostShell(
                command: remote("cat /tmp/w3-interposer.log") + " > \"\(outputDir)/w3-interposer.boot.txt\" && wc -l \"\(outputDir)/w3-interposer.boot.txt\"",
                label: "retrieve interposer-load log to host"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e1.txt") + " > \"\(outputDir)/w3-mem-diff-e1.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e1.txt\"",
                label: "retrieve mem-diff edit-1"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e2.txt") + " > \"\(outputDir)/w3-mem-diff-e2.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e2.txt\"",
                label: "retrieve mem-diff edit-2"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e3.txt") + " > \"\(outputDir)/w3-mem-diff-e3.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e3.txt\"",
                label: "retrieve mem-diff edit-3"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e4.txt") + " > \"\(outputDir)/w3-mem-diff-e4.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e4.txt\"",
                label: "retrieve mem-diff edit-4"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e5.txt") + " > \"\(outputDir)/w3-mem-diff-e5.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e5.txt\"",
                label: "retrieve mem-diff edit-5"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e6.txt") + " > \"\(outputDir)/w3-mem-diff-e6.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e6.txt\"",
                label: "retrieve mem-diff edit-6"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e7.txt") + " > \"\(outputDir)/w3-mem-diff-e7.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e7.txt\"",
                label: "retrieve mem-diff edit-7"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e8.txt") + " > \"\(outputDir)/w3-mem-diff-e8.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e8.txt\"",
                label: "retrieve mem-diff edit-8"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e9.txt") + " > \"\(outputDir)/w3-mem-diff-e9.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e9.txt\"",
                label: "retrieve mem-diff edit-9"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e10.txt") + " > \"\(outputDir)/w3-mem-diff-e10.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e10.txt\"",
                label: "retrieve mem-diff edit-10"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e11.txt") + " > \"\(outputDir)/w3-mem-diff-e11.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e11.txt\"",
                label: "retrieve mem-diff edit-11"),
            .hostShell(
                command: remote("cat /tmp/w3-mem-diff-e12.txt") + " > \"\(outputDir)/w3-mem-diff-e12.txt\" && wc -l \"\(outputDir)/w3-mem-diff-e12.txt\"",
                label: "retrieve mem-diff edit-12"),
            .screenshot(label: "07-complete"),
            .log("artifacts retrieved to \(outputDir)/"),
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
                + "sudo chown root:wheel /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("vzvz"),  // sudo password (first sudo of the session)
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
            .type("vz"),
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

            .type("vz"),
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
            .type("ls -la /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist && echo PLIST_EXISTS || echo PLIST_MISSING"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "04-plist-exists"),

            // Is its content parseable?
            .type("plutil -p /Library/LaunchDaemons/com.vz.bootstrap-ssh.plist"),
            .key(.returnKey),
            .wait(seconds: 2),
            .screenshot(label: "05-plist-content"),

            // Did launchd auto-load our daemon? (sudo will prompt.)
            .type("sudo launchctl print system/com.vz.bootstrap-ssh"),
            .key(.returnKey),
            .wait(seconds: 2),
            .type("vz"),
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
            // "vz". The bundle's sshUsername in config.json
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
            .type("vzvz"),  // Password
            .wait(seconds: 0.5),
            .clickByText("Verify Password"),
            .wait(seconds: 0.5),
            .type("vzvz"),  // Verify Password
            .wait(seconds: 1),
            .screenshot(label: "12-account-filled"),

            .clickByText("Continue"),
            // Account creation is the slowest step — macOS provisions
            // the home dir, dslocal records, indexes etc. We caught
            // "Creating account..." still showing after 20s, so give
            // it a full minute.
            .wait(seconds: 60),
            .screenshot(label: "13-after-account-continue"),

            .verifyText("Sign In to Your Apple Account"),
            .clickByText("Other Sign-In Options"),
            .wait(seconds: 2),
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

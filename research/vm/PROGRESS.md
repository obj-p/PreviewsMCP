# research/vm/ — Progress

End-of-session status doc for the JIT-spike VM kit. Captures what's
working, what's left, and how to pick up where this left off. Updated
2026-05-18.

## Where we are

**SSH provisioning works end-to-end on macOS 26.3.1.** From a fresh
IPSW install, the pipeline now reaches a snapshot from which
`previewsvm boot <bundle> && previewsvm ssh <bundle> uname -a`
succeeds on first attempt.

Working bundle for verification: `/tmp/verify.bundle` (NOT in repo).
Snapshots inside it:
- `base` — post-install, pre-SA
- `post-sa` — post-SA, at desktop (admin user `admin`/`previewsvm`)
- `post-ssh` — sshd auto-starts on boot, host key authorized, app
  firewall off, graceful-shutdown-friendly (admin user can `sudo -S
  shutdown`). **The new high-value checkpoint** — from here on,
  downstream automation runs over SSH, no more OCR or keyboard
  scripting.

## Done (working today)

| Capability | Implementation |
|---|---|
| IPSW resolution (cache / download / local) | `IPSWStore` |
| Bundle prep (disk.img, aux.img, hw-model, machine-id, SSH key, config.json) | `BundleProvisioner` |
| Headless `VZMacOSInstaller` drive | `Installer` |
| VNC transport (private `_VZVNCServer` SPI + minimal RFB 3.8 client) | `VNCSPI` + `RFBClient` + `Sources/PreviewsVMObjC/PVMVNCBridge.m` |
| Vision.framework OCR (exact-match-preferred, normalized→framebuffer coord translation) | `FramebufferOCR` |
| AppKit hidden-window host (chrome-free framebuffer capture via `view.cacheDisplay`) | `FirstBootHost` + `Screenshot.captureContentView` |
| APFS-clonefile snapshot/restore (sub-100ms) | `SnapshotStore` + `previewsvm snapshot ...` |
| Setup Assistant driver: verifyText-gated, retry-with-restore, full 16-screen macOS 26.3.1 sequence | `SetupAssistantSequence.runVNC` + `SetupCommand.exploreClickVNCSteps` |
| Shift-aware `.type()`: synthesizes Shift modifier for shifted-ASCII keysyms (`~`, `&`, `>`, `|`, `_`, uppercase) since `_VZVNCServer` drops the implicit shift | `SetupAssistantSequence.shiftedAsciiBase` |
| SSH provisioning: login → Spotlight Terminal → persistent `/Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist` that enables+bootstraps sshd on every boot, pubkey install via hex+xxd, firewall disable, graceful shutdown | `SetupCommand.provisionSSHSteps` |
| Debug preset for SSH-state inspection (plist parse, daemon state, port 22 listener, firewall state, btm) | `SetupCommand.debugSSHStateSteps` |
| boot / ssh / stop / status (already-installed bundles) | `BootCommand` etc. |

## Remaining (the path to W1 done-criterion)

The W1 done-criterion is *"single command → lldb attached to
`XCPreviewAgent` inside a SIP+AMFI-off VM."* From `post-ssh`:

1. ~~**Verify `post-sa` boots without re-running SA.**~~ Done — lands
   at lock screen for admin, `.AppleSetupDone` persisted across the
   force-stop.

2. ~~**SSH provisioning.**~~ Done — `previewsvm setup <bundle>
   --preset provision-ssh --transport vnc --retry N --restore-from
   post-sa` + `previewsvm snapshot take <bundle> post-ssh` produces a
   bundle where cold-boot → `previewsvm ssh <bundle> uname -a` works
   on first attempt. Cost: ~5 min wall time per provisioning run.

3. **SIP off via recoveryOS** (Task #14a, ~1 hour)
   - `VZVirtualMachineStartOptions.startUpFromMacOSRecovery = true`
     (macOS 14+ API).
   - Boot into recoveryOS; bring up Terminal from the Utilities menu.
   - Run `csrutil disable`. Reboot.
   - **No SSH inside recoveryOS** — OCR + keyboard scripting is the
     transport. Reuses the existing `runVNC` machinery + shift-aware
     `.type` for any shell punctuation needed.
   - Snapshot as `post-sip`.

4. **AMFI off** (Task #14b, ~10 min)
   - SSH in, `sudo nvram boot-args="amfi_get_out_of_my_way=1"`, reboot.
   - Verify by inspecting `nvram boot-args` over SSH.
   - Snapshot.

5. **Xcode install** (Task #14c, ~30-60 min wall time)
   - SSH in, `curl -O https://...Xcode_NN.xip`, `xip -x Xcode.xip`,
     move to `/Applications/`.
   - `sudo xcodebuild -license accept` if needed.
   - Snapshot as `post-xcode-sip-amfi` — **the research-session base.**

6. **JIT spike research begins** (the actual W1 work)
   - Per-session: `previewsvm snapshot restore <bundle> post-xcode-sip-amfi && previewsvm boot <bundle>`
   - `previewsvm ssh <bundle> -- "sudo dtrace -n '...' -p $(pgrep XCPreviewAgent)"`
   - `previewsvm ssh <bundle> -- "lldb -p $(pgrep XCPreviewAgent)"`
   - Findings go to `prompts/jit-executor-findings.md`.

## How to use today (current state)

```bash
cd research/vm

# Build + sign (codesign with com.apple.security.virtualization entitlement)
./build.sh release

# One-time fresh install from an IPSW URL or local path. Cached.
.build/release/previewsvm install ./my.bundle --ipsw <url-or-path>

# Snapshot the post-install state before driving SA.
.build/release/previewsvm snapshot take ./my.bundle base

# Drive Setup Assistant. Boot variability means retry is essential.
.build/release/previewsvm setup ./my.bundle \
    --preset explore-click-vnc --transport vnc \
    --retry 10 --restore-from base

# Once it succeeds (5-15 min wall time depending on retries), snapshot
# the desktop state.
.build/release/previewsvm snapshot take ./my.bundle post-sa

# Provision SSH (enable sshd via custom LaunchDaemon, install pubkey,
# disable firewall, graceful shutdown). ~5 min.
.build/release/previewsvm setup ./my.bundle \
    --preset provision-ssh --transport vnc \
    --retry 2 --restore-from post-sa

.build/release/previewsvm snapshot take ./my.bundle post-ssh

# Validate.
.build/release/previewsvm boot ./my.bundle --skip-ssh-wait &
sleep 30  # boot + sshd come up
.build/release/previewsvm ssh ./my.bundle uname -a

# Inspect screenshots from the successful attempt.
ls /tmp/previewsvm-setup/attempt-N/
```

## Known issues + invariants

- **Language→Region transition is the dominant SA flake** (30-50% per
  attempt). Caused by macOS menu-bar focus stealing the keyboard event.
  No code fix works reliably; the retry-with-restore loop handles it.
- **Account creation needs ~60s of post-Continue wait.** macOS
  provisions home dir, dslocal records, indexes.
- **Modal confirmation dialogs need exact-match OCR.** `Skip` would
  match `Don't Skip` by substring; same for `Agree` / `Disagree`.
  Fixed in `FramebufferOCR.find` — prefers exact text matches.
- **Screenshot for OCR must be chrome-free.** `screencapture -l
  <windowID>` includes the title bar and shifts coords ~20px.
  `Screenshot.captureContentView` (which uses
  `NSView.cacheDisplay(in:to:)`) gives a 1280×720 framebuffer-aligned
  image.
- **`_VZVNCServer` drops the implicit Shift modifier on shifted-ASCII
  keysyms.** Sending X11 keysym 0x26 (`&`) delivers `7`; sending 0x41
  (`A`) delivers `a`; etc. `SetupAssistantSequence.shiftedAsciiBase`
  maps each shifted-ASCII char to its unshifted base; the `.type`
  runner wraps Shift+base around it. Found while debugging the
  pubkey-install command — the original direct `.type(pubkey)` was
  also broken for the same reason (uppercase in base64) but the
  current implementation uses hex+xxd to stay in `[0-9a-f]` for safety
  regardless.
- **macOS Tahoe SSH enablement requires a custom LaunchDaemon.**
  `systemsetup -setremotelogin on` errors with "Full Disk Access
  privileges required" even under sudo (TCC). `launchctl enable +
  bootstrap` of `/System/Library/LaunchDaemons/ssh.plist` works
  in-session but the enable record either doesn't persist or isn't
  honored on cold boot. Workaround: drop
  `/Library/LaunchDaemons/com.previewsvm.bootstrap-ssh.plist` with
  `RunAtLoad=true` and a shell command that re-runs enable+bootstrap
  on every boot. `/Library/LaunchDaemons` is outside SSV and
  auto-loaded by launchd at boot.
- **Host ↔ VM bridge can need a warmup after first boot.** Empirically
  the first 1-2 minutes after a fresh VM cold-boot can return
  "No route to host" from `ping`/`ssh` even though DHCP succeeded and
  the guest's `lsof` shows port 22 listening. Eventually clears on its
  own. The `PRIVATE` flag on the `bridge100` member (visible in
  `ifconfig bridge100`) was a false-positive diagnosis: BSD semantics
  say it only isolates between private members, not bridge→member, and
  `ifconfig -private` isn't even valid on Tahoe. Keep
  `previewsvm setup --preset debug-ssh-state` around for future
  network-vs-sshd diagnosis.
- **Coordinates + button text are pinned to macOS 26.3.1.** Expect to
  revisit per OS version. The SA wait-and-tab brittleness profile is
  the same one `cirruslabs/macos-image-templates` ships with (their
  templates also have per-version PRs).
- **Host macOS ≥ guest IPSW version.** `VZMacOSInstaller` rejects
  newer-than-host IPSWs with `VZErrorCode 10006`. Surface message in
  `Installer.install` calls this out.

## File layout

```
research/vm/
├── PROGRESS.md                          — this file
├── README.md                            — user-facing setup + roadmap
├── Package.swift
├── build.sh                             — swift build + codesign
├── Resources/previewsvm.entitlements
├── Sources/
│   ├── PreviewsVMKit/                   — library
│   │   ├── Support.swift                — VMError + Log
│   │   ├── VMBundle.swift               — on-disk layout
│   │   ├── VMConfiguration.swift        — VZ config builder (graphics + keyboard + pointer required)
│   │   ├── VMHost.swift                 — @MainActor VZ lifecycle
│   │   ├── VMNetwork.swift              — /var/db/dhcpd_leases parser
│   │   ├── VMSSH.swift                  — /usr/bin/ssh wrapper
│   │   ├── PidFile.swift                — boot↔stop coord
│   │   ├── IPSWStore.swift              — IPSW download/cache/load
│   │   ├── BundleProvisioner.swift      — fresh-bundle prep from IPSW
│   │   ├── Installer.swift              — VZMacOSInstaller drive
│   │   ├── FirstBootHost.swift          — hidden NSWindow + VZVirtualMachineView
│   │   ├── KeyboardScripter.swift       — NSEvent-based (legacy; not used post-VNC)
│   │   ├── VNCSPI.swift                 — wraps _VZVNCServer via Obj-C bridge
│   │   ├── RFBClient.swift              — minimal RFB 3.8 client
│   │   ├── FramebufferOCR.swift         — Vision.framework wrapper
│   │   ├── SetupAssistantSequence.swift — Step enum + runVNC + Screenshot utilities
│   │   └── SnapshotStore.swift          — APFS clonefile snapshot/restore
│   ├── PreviewsVMObjC/
│   │   ├── include/PVMVNCBridge.h
│   │   └── PVMVNCBridge.m               — _VZVNCServer SPI bridge
│   └── previewsvm/                      — CLI
│       ├── Main.swift                   — @main; NSApp.run() for AppKit
│       ├── BundleArgument.swift         — shared @OptionGroup
│       ├── SignalWaiter.swift           — SIGINT/SIGTERM → CheckedContinuation
│       ├── BootCommand.swift            — boot + boot --with-display
│       ├── SSHCommand.swift
│       ├── StopCommand.swift
│       ├── StatusCommand.swift
│       ├── InstallCommand.swift         — install pipeline entry
│       ├── SnapshotCommand.swift        — take/restore/list/delete
│       ├── SetupCommand.swift           — SA driver presets, retry loop
│       ├── TestKeysCommand.swift        — phase 11b NSEvent verification (legacy)
│       └── TestVNCCommand.swift         — phase 11d VNC smoke test
```

## Big design decisions (with links to memory)

See the project memory files under
`~/.claude/projects/-Users-jasonprasad-Projects-PreviewsMCP/memory/`:

- `project-vm-kit-extractable` — the kit is a future candidate for
  extraction to its own repo. Keep PreviewsMCP-specific coupling out.
- `project-vm-setup-assistant-via-snapshot` — earlier first-boot
  strategy notes (now superseded by the working approach captured in
  this PROGRESS.md and the next memory).
- `project-vm-sa-complete-macos-26-3-1` — the canonical SA sequence
  + empirical findings from getting it working.

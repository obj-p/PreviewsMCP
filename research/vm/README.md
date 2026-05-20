# research/vm/

`previewsvm` — a Swift CLI wrapping `Virtualization.framework` so the
JIT-executor spike has a reproducible, disposable macOS VM where dtrace
and lldb can attach to entitlement-restricted Apple binaries
(`XCPreviewAgent`, `previewsd`, `PreviewShellMac`).

This is the **W1 harness** from
[`prompts/jit-executor-research.md`](../../prompts/jit-executor-research.md).
The spike's done-when criterion is:

> a contributor can clone the repo, run a single command, and end up at
> an lldb prompt attached to a running `XCPreviewAgent` inside a clean
> VM. No manual recoveryOS dance per session.

This README tracks how close we are to that and what's still stubbed.

## Status

| Capability | State | Where |
|---|---|---|
| Boot an already-installed VM bundle | ✅ shipped | `BootCommand` + `VMHost` |
| Discover the guest IP from DHCP leases | ✅ shipped | `VMNetwork` |
| Exec a command over SSH (or open a shell) | ✅ shipped | `SSHCommand` + `VMSSH` |
| Graceful shutdown via SIGTERM from another shell | ✅ shipped | `StopCommand` |
| Status / liveness reporting | ✅ shipped | `StatusCommand` |
| Resolve IPSW (download / cache / local path) | ✅ shipped | `IPSWStore` |
| Prep a fresh bundle (disk, aux, hw-model, machine-id, SSH key, config) | ✅ shipped | `BundleProvisioner` |
| Drive `VZMacOSInstaller` headless against a prepped bundle | ✅ shipped | `Installer` |
| First-boot Setup Assistant driver (scripted keyboard events) | 🚧 not started | — (#11) |
| Post-Setup Remote Login + SSH key drop | 🚧 not started | — (#12) |
| Snapshot / restore (VZ snapshot API) | 🚧 not started | — (#13) |
| Recovery-boot for `csrutil disable` | 🚧 not started | — (#14) |
| Set `amfi_get_out_of_my_way=1` in NVRAM | 🚧 not started | — (#14) |
| Reproducible Xcode install inside the guest | 🚧 not started | — (#14) |
| Python dtrace/lldb harness on top | 🚧 not started | `research/scripts/` (planned) |

The single-command done-criterion lights up once the install pipeline +
provisioning + snapshot lands.

## Layout

```
research/vm/
├── README.md                  — this file
├── Package.swift              — separate Swift package (not in root Package.swift)
├── build.sh                   — wraps `swift build` + codesign with entitlements
├── Resources/
│   └── previewsvm.entitlements
└── Sources/
    ├── PreviewsVMKit/         — library (the on-disk dir is `PreviewsVMKit`
    │                            rather than `PreviewsVM` because APFS is
    │                            case-insensitive and would collapse it
    │                            against `previewsvm/`)
    │   ├── Support.swift              — VMError + Log
    │   ├── VMBundle.swift             — on-disk layout + config codec
    │   ├── VMConfiguration.swift      — VZVirtualMachineConfiguration builder
    │   ├── VMHost.swift               — @MainActor VZ lifecycle wrapper
    │   ├── VMNetwork.swift            — /var/db/dhcpd_leases parser
    │   ├── VMSSH.swift                — /usr/bin/ssh exec wrapper
    │   ├── PidFile.swift              — boot↔stop coordination
    │   ├── IPSWStore.swift            — IPSW download / cache / load
    │   ├── BundleProvisioner.swift    — fresh-bundle prep from an IPSW
    │   └── Installer.swift            — VZMacOSInstaller drive
    └── previewsvm/            — CLI target (binary name `previewsvm`)
        ├── Main.swift
        ├── BootCommand.swift
        ├── SSHCommand.swift
        ├── StopCommand.swift
        ├── StatusCommand.swift
        ├── InstallCommand.swift   — install pipeline entry
        ├── BundleArgument.swift
        └── SignalWaiter.swift
```

## Build

```bash
./build.sh                        # debug build + codesign
./build.sh release                # release build + codesign
```

`swift build` alone is not enough — `Virtualization.framework` refuses to
init a VM unless the calling binary carries `com.apple.security.virtualization`.
`build.sh` ad-hoc-signs the SPM output with the entitlement plist in
`Resources/`. Ad-hoc signing (`codesign -s -`) is sufficient on a research
host; a Developer ID identity is only required for distribution.

The signed binary lives at:

```
$(swift build --show-bin-path)/previewsvm
```

## Usage today

```bash
# Install a fresh macOS into a new bundle. Resolves the IPSW (download,
# cache, or local path), preps the bundle directory, and drives
# VZMacOSInstaller headless. The result still has Setup Assistant
# pending — the first-boot driver lands in a follow-up.
previewsvm install ./my.bundle --ipsw https://updates.cdn-apple.com/.../Restore.ipsw
previewsvm install ./my.bundle --ipsw ~/Downloads/UniversalMac.ipsw
previewsvm install ./my.bundle                 # downloads `latest` via VZMacOSRestoreImage

# Prep only (no install) for plumbing tests / debugging:
previewsvm install ./my.bundle --ipsw … --skip-install

# Inspect a bundle's state (PID file, lease, ssh reachability):
previewsvm status ./my.bundle

# Boot a bundle in the foreground. Blocks; ^C to stop.
previewsvm boot ./my.bundle

# From another shell, while `boot` is up:
previewsvm ssh ./my.bundle -- uptime
previewsvm ssh ./my.bundle                     # interactive shell
previewsvm stop ./my.bundle                    # graceful

# Force-stop (skip guest cooperation):
previewsvm stop ./my.bundle --force
```

`PREVIEWSVM_DEBUG=1` enables verbose logging on stderr (poll cadences,
SSH probe diagnostics, VM state transitions).

## Bundle layout

```
mybundle.bundle/
├── config.json                — see VMBundle.BundleConfig
├── disk.img                   — main filesystem image
├── aux.img                    — VZMacAuxiliaryStorage (NVRAM)
├── machine-identifier.bin     — VZMacMachineIdentifier dataRepresentation
├── hardware-model.bin         — VZMacHardwareModel dataRepresentation
├── id_ed25519                 — SSH private key (mode 0600)
├── id_ed25519.pub             — SSH public key (provisioned into guest)
├── known_hosts                — written by ssh on first connect
└── running.pid                — present while `boot` is alive
```

Example `config.json`:

```json
{
    "cpuCount": 6,
    "memorySizeBytes": 12884901888,
    "macAddress": "52:54:00:12:34:56",
    "sshUsername": "admin",
    "sshKeyName": "id_ed25519"
}
```

Today `previewsvm install` produces a freshly-installed but
UNPROVISIONED bundle (Setup Assistant has not yet run). For the bundle
to be usable, the user currently has to attach a display some other way
to click through Setup Assistant. The first-boot driver below fixes
that.

## Roadmap

The single-command done-criterion lights up in roughly this order.
Each step is small enough to land as a discrete PR-equivalent.

1. ✅ **Resolve IPSW + prep bundle.** `IPSWStore` + `BundleProvisioner`.
2. ✅ **Drive `VZMacOSInstaller` headless.** `Installer.install`. The
   resulting bundle's `disk.img` holds a fresh macOS, with Setup
   Assistant pending.
3. **First-boot Setup Assistant driver (scripted keyboard events).**
   Add `VZMacGraphicsDeviceConfiguration` + `VZUSBKeyboardConfiguration`
   to the post-install VM config (display required, window not
   required), then drive a version-pinned keyboard script through
   Setup Assistant: language, region, T&Cs, admin user. Same
   wait-and-tab brittleness profile as `cirruslabs/macos-image-templates`
   — well-trodden, manageable maintenance cost. Filesystem injection
   was considered and ruled out per
   [memory](../../). See
   `prompts/jit-executor-research.md` and the `project-vm-setup-assistant-via-snapshot`
   memory entry for why.
4. **Post-Setup provisioning.** Continue the keyboard script after
   Setup Assistant lands at the desktop: open Terminal, enable Remote
   Login (`sudo systemsetup -setremotelogin on`), drop the bundle's
   ed25519 pubkey into `~admin/.ssh/authorized_keys`. From here on
   out, `previewsvm boot` + `previewsvm ssh` work CLI-only.
5. **`snapshot` / `restore`.** macOS 14 added VZ snapshots. Take a
   `base` snapshot after first-boot provisioning; every research
   session `restore`s to it so accumulated state never contaminates
   traces. This is what makes the per-session Setup-Assistant cost
   one-shot rather than per-bundle.
6. **Recovery-boot for `csrutil disable`.** `VZVirtualMachineStartOptions`
   exposes `startUpFromMacOSRecovery` (macOS 14+). Same scripted-keyboard
   approach as Setup Assistant — boot into recoveryOS, open Terminal,
   run `csrutil disable`, reboot.
7. **AMFI off via NVRAM boot-args.** `nvram boot-args="amfi_get_out_of_my_way=1"`.
   Done from within the guest over SSH after SIP is off. Reboot, verify.
8. **Reproducible Xcode install.** Probably `Xcode_NN.xip` from a
   known URL, downloaded over SSH from inside the guest. Slowest step;
   the post-Xcode snapshot below saves us from redoing it per session.
9. **`base-xcode` snapshot.** Re-snapshot after Xcode + SIP/AMFI off.
   This is the snapshot the JIT-spike research workflow `restore`s
   to per session.
7. **`previewsvm dtrace …` / `previewsvm lldb …`.** Thin wrappers
   over `ssh` that compose with the dtrace/lldb scripts in
   `research/scripts/`. Eventually the harness in `research/scripts/`
   subsumes these.

## Entitlements

`Resources/previewsvm.entitlements`:

| Key | Why |
|---|---|
| `com.apple.security.virtualization` | Required to instantiate `VZVirtualMachine`. Without this the binary aborts at the first VZ API call. |
| `com.apple.security.network.server` | `VZNATNetworkDeviceAttachment` opens a `vmnet` pipe; macOS classifies that as a network server. |
| `com.apple.security.network.client` | Outbound SSH from the host to the guest's NAT IP. |

For installer-mode (later) we may also need:

- `com.apple.security.cs.disable-library-validation` — only if we end
  up loading a debug variant of `VirtualizationCore` for tracing.
- `com.apple.security.iokit-user-client-class` — only if we add
  framebuffer capture.

Both are deferred until they're actually needed.

## Concurrency notes

- `VMHost`, `VMConfiguration.build`, and everything that touches a
  `VZ…` type is `@MainActor`. `VZVirtualMachine` requires its methods
  to be called on the queue it was created with; pinning everything to
  the main actor lets Swift 6 strict-concurrency enforce that.
- `VMSSH.exec` does its work inside a `Task.detached` so process
  spawning + pipe draining doesn't run on the main actor. Pipes are
  drained concurrently via `readabilityHandler` so the child can't
  wedge on a full 64 KiB pipe buffer.
- `SignalWaiter` bridges `DispatchSourceSignal` (which fires on a
  dispatch queue) to a `CheckedContinuation` so `BootCommand.run`
  can `await` SIGINT/SIGTERM. The dispatcher is `@unchecked Sendable`
  because an `NSLock` guards the one shared continuation slot.

## Non-goals

- **No Tart / UTM / macosvm dependency.** Tart is Fair Source; UTM is
  GPL-3.0; `macosvm` is permissively-licensed but minimally maintained.
  Our automation surface is small (boot/snapshot/restore/exec), so a
  thin in-repo wrapper is cheaper than vendoring any of those.
- **No GUI.** Headless only. The framebuffer device is omitted from
  `VMConfiguration.build`. Adding one later for screenshot debugging
  is a one-line change.
- **No iOS / Linux guests.** macOS only; the only reason this harness
  exists is to debug Apple binaries that require macOS host + macOS
  guest.
- **No production code reuse.** Nothing in `research/vm/` is meant to
  graduate into `Sources/`; the spike's deliverables outlive it, not
  the harness itself (see jit-executor-research.md → "Non-goals").

## Caveats

- **Host macOS must be ≥ the guest IPSW's macOS.** `VZMacOSInstaller`
  refuses to install a guest macOS newer than the host with
  `VZErrorCode 10006` ("Installation requires a software update").
  `Installer.install` traps this error and surfaces a pointed message
  with the host version. Workarounds: update the host, or supply
  `--ipsw <path-to-older-ipsw>` whose macOS ≤ host. The
  `VZMacOSRestoreImage.fetchLatestSupported` default will always pull
  the newest IPSW and hit this rule whenever Apple ships an OS update
  before the host has been bumped.
- **Apple Silicon host only.** `Virtualization.framework` only supports
  macOS guests on Apple Silicon. Intel hosts are not supported and will
  not be.
- **DHCP-lease discovery polls `/var/db/dhcpd_leases`.** That file is
  written by `bootpd` after the guest sends its DHCPDISCOVER, which
  happens during the guest's network bring-up. On a clean boot expect
  10–30 s before a lease appears; on a snapshot-restored VM it's
  usually under 5 s. `--ip-timeout` defaults to 120 s.
- **NAT means the guest IP is on `192.168.64.0/24`** (or whatever
  `vmnet` is using). Multiple bundles can run concurrently; their NAT
  IPs come from the same pool, so the MAC address in `config.json` is
  the only stable handle.

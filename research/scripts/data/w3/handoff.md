# W3 — Per-edit `__xojit_executor_write_mem` capture: session handoff

**Status:** End-to-end Xcode driving WORKS reliably. Final-mile capture is
BLOCKED on lldb's symbol resolution against an attached `XCPreviewAgent`. The
next-attempt fork is a `DYLD_INSERT_LIBRARIES`-style interposer dylib that
bypasses lldb + dtrace entirely.

**Scope of this doc.** (1) Review the just-finished session so a fresh agent
knows what was learned and where time was burned. (2) A self-contained
continuation prompt for the next session. (3) Feasibility check on the
interposer approach, with the constraints that actually bind on a SIP-off +
AMFI-off VM.

---

## Table of Contents

- [Session review (what's been done)](#session-review)
- [Continuation prompt (for fresh context)](#continuation-prompt)
- [Interposer feasibility check](#interposer-feasibility)

---

## Session review

### What this session delivered

The W3 mechanism-level closure landed early in the session and was committed at
`94c86a1` ("research/scripts/: W3 — XCPreviewAgent lifecycle + patch-point set"),
producing:

- `research/scripts/analysis/w3-lifecycle-timeline.md` — agent's three-path
  decision tree, env-var consumption, message order, all grounded in static
  analysis + observed stderr.
- `research/scripts/analysis/w3-patch-point-set.md` — Apple's runtime IS LLVM
  `SimpleRemoteEPC`; host computes patches, agent applies them via
  `___xojit_executor_write_mem` (option (a) in-place `mprotect`+`memcpy`).

The design doc that depends on those findings (`prompts/jit-executor-design.md`,
commit `c8056de`) also landed.

### Where the session burned its budget: the W3 address-list capture

The patch-point set was closed at the **mechanism** level. The
**address-list-per-edit-kind** sub-task (per `w3-patch-point-set.md` §6) calls
for a dtrace/lldb capture of `___xojit_executor_write_mem` calls during a real
Xcode hot-reload — multi-hour GUI-automation work the spike treats as
post-spike production-hardening, but worth attempting now to harden the design
doc's §2 table.

This session attempted that capture. Two write-ups document the journey:

- `research/scripts/data/w3/xcode-driving-attempt.md` (commit `53915a7`,
  `b416692`) — the *first* dead-end: System Events / accessibility scripting
  over SSH times out (-1712) because the SSH session can't inherit TCC
  Accessibility. Conclusion: a custom `previewsvm` preset with VNC-driven
  keystrokes is required.
- `research/scripts/data/w3/canvas-driving-results.md` (commit `e0db725`) — the
  *current* dead-end: the `drive-xcode-preview` preset works end-to-end through
  preview rendering, but lldb cannot resolve `__xojit_executor_*` breakpoints
  against the attached agent.

### Load-bearing facts established this session

The next agent should *not* re-derive any of these. Each was a meaningful
discovery cost.

1. **Xcode 26.2 repurposed `Cmd+Option+Return`.** The canvas-activation
   keystroke from prior Xcodes now opens "Coding Intelligence." The reliable
   path is `Cmd+Shift+/` (Help menu search) → type "Canvas" → `Down` → `Return`.
   This activates `Editor → Canvas` regardless of its current binding. Proof
   screenshot: `research/scripts/data/w3/16-03g-after-help-canvas-enter.png`
   (preview renders the `Hello`/`World` text in blue).
2. **Library target, not executable.** A `Package.swift` with an `@main` +
   `main.swift` had a compile error that prevented preview activation. The
   working shape is a library target with a single `ContentView.swift`
   containing `#Preview { ContentView() }`. Embedded in the preset.
3. **`XCPreviewAgent` spawns reliably** once the canvas opens. Polling
   `pgrep -f XCPreviewAgent` over SSH succeeds within ~30s. The agent is up,
   the preview renders, the hot-reload pipeline is live.
4. **lldb cannot resolve breakpoints on the attached agent.** `target create
   --arch arm64e <agent>` reports success, but `process attach -p $PID`
   immediately reports "Target 0: (No executable module.)" and all
   `__xojit_executor_*` breakpoints stay pending. Variants tried (positional
   binary, no binary, separate `-O` ordering) — all the same.
5. **The agent gets SIGKILL within seconds of `continue`.** Almost certainly
   previewsd's IPC heartbeat timeout fires during lldb's attach pause. Even if
   breakpoints DID resolve, the window is short.
6. **dtrace is blocked too.** Apple's `dtrace` has an internal `dt_proc_create`
   gate that fails for the agent even with SIP off + AMFI off (per
   `xcode-driving-attempt.md`'s "additional unblock paths").
7. **Reusable infrastructure that landed:** `drive-xcode-preview` preset in
   `research/vm/Sources/previewsvm/SetupCommand.swift` (~300 LOC), new
   `.dualModifiedKey` and `.hostShell` step types in
   `SetupAssistantSequence.swift`, and the `post-autologin-w3` VM snapshot in
   `/tmp/verify.bundle/snapshots/`. The preset works in ~6 min wall time per
   run.

### Snapshot state on disk

`ls /tmp/verify.bundle/snapshots/`:

```
base                  # initial VM image
post-amfi             # SIP-on, AMFI off
post-autologin-w3     # *** start here ***  — auto-login + xcodebuild -runFirstLaunch done
post-sa               # Setup Assistant complete
post-sip              # SIP off
post-ssh              # SSH provisioned
post-xcode-sip-amfi   # Xcode 26.2 installed, SIP off, AMFI off
```

The `post-autologin-w3` snapshot is the launch point for any continuation —
admin auto-login is configured, `xcodebuild -runFirstLaunch` has run, and the
`~/HelloPreview/` test package is in place. Boot from there directly.

### Commits this session

```
e0db725  research/vm/: drive-xcode-preview preset — full Xcode driving, capture blocked
b416692  research/scripts/data/w3/xcode-driving-attempt.md: dead-end pass
53915a7  research/scripts/data/w3/: Xcode-driving attempt — blocked, documented
c8056de  prompts/jit-executor-design.md: design doc for the custom JIT executor
b732128  prompts/jit-executor-findings.md: mark W3 mechanism-level closure
94c86a1  research/scripts/: W3 — XCPreviewAgent lifecycle + patch-point set
```

The VM is currently force-stopped (the preset's terminal step is
`forceStop`); no live state to drain.

---

## Continuation prompt

> I'm picking up the JIT-executor research spike at workstream W3 again. The
> mechanism-level closure already landed (`94c86a1`); the address-list
> sub-task is still open. The previous session built a working end-to-end
> Xcode driver (`drive-xcode-preview` preset, commit `e0db725`) but
> lldb and dtrace are both blocked against `XCPreviewAgent`. The proposed
> next move is a `DYLD_INSERT_LIBRARIES` interposer dylib that re-exports
> the four `__xojit_executor_*` symbols with a logging wrapper, bypassing
> lldb entirely.
>
> **Required reading, in order:**
>
> 1. `research/scripts/data/w3/handoff.md` (this file — session review + the
>    plan).
> 2. `research/scripts/data/w3/canvas-driving-results.md` — the dead-end
>    that motivates this session. Pay attention to "What works end-to-end"
>    (don't re-derive any of it) and "Per-edit address-list capture: where
>    to go next" → option 1.
> 3. `research/scripts/analysis/w3-patch-point-set.md` §6 — what the
>    address-list capture is supposed to produce. The dtrace script at
>    `research/scripts/data/w3/capture-write-mem.d` is the prior approach;
>    the interposer is a drop-in replacement at the "observe write_mem"
>    level.
> 4. `research/scripts/data/w3/agent-metadata.txt` — confirms the agent
>    carries only `com.apple.security.get-task-allow`, no
>    `com.apple.security.cs.*` hardened-runtime entitlements. Load-bearing
>    for the interposer feasibility.
> 5. `research/scripts/data/w3/XOJITExecutor-exports.txt` — the four C-style
>    symbols to interpose: `___xojit_executor_write_mem`,
>    `___xojit_executor_run_program_on_main_thread`,
>    `___xojit_executor_run_program_wrapper`, `___xojit_run_wrapper`.
> 6. `research/vm/Sources/previewsvm/SetupCommand.swift:296-680` — the
>    `drive-xcode-preview` preset that already drives the full flow. Steps
>    9-10 (lldb deploy + start) are the ones you'll replace; everything
>    else stays.
>
> **Single concrete goal:** capture the per-edit `write_mem` address list
> via a `DYLD_INSERT_LIBRARIES` interposer dylib. Success = a log file
> with at least 1 hot-reload-edit's worth of `write_mem(addr, len)` lines
> plus the calling-thread ustack (or at minimum the addr+len tuples).
>
> **Out of scope:**
> - Don't redo the lldb iterations. They're conclusively blocked.
> - Don't re-investigate the canvas-toggle keystroke. Help-menu-search
>   path is locked in.
> - Don't add System Events / accessibility paths over SSH. -1712 closes
>   that.
>
> **Snapshot to restore:** `post-autologin-w3` under
> `/tmp/verify.bundle/snapshots/`. Boot from there; admin auto-login +
> `xcodebuild -runFirstLaunch` + `~/HelloPreview/` are already in place.
> The preset boots from this snapshot by default.
>
> **Starting move:** write a minimal `interposer.dylib`. The cleanest
> Mach-O `__DATA,__interpose`-table form is C:
>
> ```c
> // interposer.c
> #include <stdio.h>
> #include <stdint.h>
> #include <unistd.h>
> #include <pthread.h>
>
> static FILE *g_log = NULL;
> static pthread_once_t g_once = PTHREAD_ONCE_INIT;
> static void open_log(void) {
>     g_log = fopen("/tmp/w3-writes.log", "a");
>     if (g_log) setvbuf(g_log, NULL, _IOLBF, 0);
> }
>
> // Real symbol declarations (the four exports we want to observe).
> extern int __xojit_executor_write_mem(void *addr, const void *bytes, uint64_t len);
> extern int __xojit_executor_run_program_on_main_thread(void *fn, void *args);
>
> static int my_write_mem(void *addr, const void *bytes, uint64_t len) {
>     pthread_once(&g_once, open_log);
>     if (g_log) fprintf(g_log, "write_mem addr=%p len=%llu tid=%p\n",
>                        addr, (unsigned long long)len,
>                        (void *)pthread_self());
>     return __xojit_executor_write_mem(addr, bytes, len);
> }
>
> static int my_run_program(void *fn, void *args) {
>     pthread_once(&g_once, open_log);
>     if (g_log) fprintf(g_log, "run_program fn=%p\n", fn);
>     return __xojit_executor_run_program_on_main_thread(fn, args);
> }
>
> __attribute__((used)) static struct {
>     const void *replacement;
>     const void *replacee;
> } interposers[] __attribute__((section("__DATA,__interpose"))) = {
>     { (const void *)&my_write_mem,
>       (const void *)&__xojit_executor_write_mem },
>     { (const void *)&my_run_program,
>       (const void *)&__xojit_executor_run_program_on_main_thread },
> };
> ```
>
> Build via SSH on the guest (toolchain present): `clang -dynamiclib -arch
> arm64e -o /tmp/w3-interposer.dylib /tmp/interposer.c` (no codesign needed
> on a SIP-off + AMFI-off VM). Host-build + scp also works.
>
> **The injection point.** Previewsd spawns XCPreviewAgent; we don't get
> to set `DYLD_INSERT_LIBRARIES` on previewsd's `posix_spawn` call
> directly. Two viable paths:
>
> - **Path A — `launchctl setenv`.** Set
>   `DYLD_INSERT_LIBRARIES=/tmp/w3-interposer.dylib` (plus
>   `DYLD_FORCE_FLAT_NAMESPACE=1` if needed for `dlopen`'d symbols — see
>   "Interposer feasibility" below) in the user's launchd session via
>   `launchctl setenv` BEFORE Xcode is opened. New `posix_spawn` calls
>   under that launchd session inherit the env. Requires the agent's not
>   already running.
> - **Path B — kill + relaunch.** After the existing `drive-xcode-preview`
>   preset gets the agent up once (so we know the pipeline works), `pkill
>   XCPreviewAgent`, then trigger another canvas re-render with the
>   `launchctl setenv`'d env already in place. Previewsd respawns the
>   agent; this time it inherits `DYLD_INSERT_LIBRARIES`.
>
> Path A first; Path B if launchctl-env timing is awkward.
>
> **Modify the preset.** Replace steps 9-10 in
> `SetupCommand.swift:driveXcodePreviewSteps` (the lldb script deploy + lldb
> start) with: (a) build/deploy the interposer dylib, (b)
> `launchctl setenv DYLD_INSERT_LIBRARIES /tmp/w3-interposer.dylib`, (c)
> ensure the agent picks it up (kill-and-respawn if needed). The
> sed-edit step (current step 11) then triggers writes through the
> interposer; output lands in `/tmp/w3-writes.log` which the preset's
> retrieval step `cat`s back.
>
> **Acceptance.** A non-empty `/tmp/w3-writes.log` with at least one
> `write_mem addr=… len=… tid=…` line tied to the `Hello`→`Howdy` edit.
> That closes the W3 address-list sub-task; update
> `w3-patch-point-set.md` §6 with the observed list and the design doc's
> §2 frequency column.
>
> If the interposer doesn't fire (no log lines despite a confirmed
> hot-reload), read this doc's "Interposer feasibility check" section and
> try the listed fallbacks (RTLD_NOW + manual `dyld_dynamic_interpose`
> after `dlopen` of PreviewsInjection, or the spawn-under-lldb approach in
> `canvas-driving-results.md` option 2).
>
> Commit naming convention from this session: short scope prefix, colon,
> verb phrase. Example: `research/vm/: w3 interposer dylib — write_mem
> address-list captured`.

---

## Interposer feasibility check

The interposer approach has three places it could fail. The agent metadata,
the dyld interpose docs, and Apple's hardened-runtime literature give a
strong-but-not-certain green light. Concrete answers below.

### Q1 — Does the agent's signing / hardened runtime block DYLD_INSERT_LIBRARIES?

**Probable answer: no, on our SIP-off + AMFI-off VM.**

The agent's entitlements (`research/scripts/data/w3/agent-metadata.txt`) are
exactly:

```
<key>com.apple.security.get-task-allow</key>
<true/>
```

Critically: **no `com.apple.security.cs.allow-dyld-environment-variables`**, and
also no entitlements that would mark this as a hardened-runtime binary
(`com.apple.security.cs.*` family is absent). The `codesign -d` output shows
`flags=0x0(none)` — i.e., the `CS_HARD` / hardened-runtime flag is NOT set.

On a stock macOS with SIP enabled, dyld still strips `DYLD_*` env vars when
the binary is a platform binary or signed-by-Apple binary (the
`AMFI_DYLD_INPUT_PROC_*` policy). Our VM has SIP off and AMFI off
(`amfi_get_out_of_my_way=1` via nvram boot-args, plus `csrutil disable`), which
removes those gates. The agent already runs with `DYLD_INSERT_LIBRARIES=
PreviewsInjection.framework/…` injected (per `w3-lifecycle-timeline.md` step 1)
which is concrete proof DYLD_INSERT works against this agent in this VM.

**Conclusion: green light, with the caveat that the agent is already getting
one DYLD_INSERT — we either replace it or chain (set
`DYLD_INSERT_LIBRARIES=<existing>:/tmp/w3-interposer.dylib`).** The chained
form preserves the JIT path; replacing it would force the agent into the
framework-fallback path and no `write_mem` would ever fire. **Always chain.**

### Q2 — Can DYLD_INSERT_LIBRARIES interpose a function from a framework that's `dlopen`'d at runtime?

**Probable answer: yes via `dyld_dynamic_interpose` (runtime API), and
yes-but-fragile via the static `__DATA,__interpose` table.**

The relevant fact from the dyld interposing literature: the `__DATA,__interpose`
table is processed by dyld when each library is loaded. If the target library
(`XOJITExecutor.framework`) is loaded **after** our interposer dylib (because
it's `dlopen`'d by PreviewsInjection at runtime), the interpose entries are
still applied — interposing is a per-library-load operation, not a one-shot
startup pass. The Mach-O `__DATA,__interpose` section applies for the lifetime
of the interposer dylib, and any subsequently-loaded library that references
the replacee gets routed through the replacement.

However, two-level namespace can interfere: if the replacee is referenced from
within `XOJITExecutor.framework` itself (an intra-library call), two-level
binding routes it directly without dyld lookup, bypassing the interpose. Setting
`DYLD_FORCE_FLAT_NAMESPACE=1` flattens this and forces dyld to consult the
interpose table on every call. **Set both env vars when injecting.**

If the static `__DATA,__interpose` table approach fails to catch any calls
(no log lines despite a confirmed reload), the fallback is the runtime API
`dyld_dynamic_interpose`: in the interposer's static initializer
(`__attribute__((constructor))`), spin a thread that polls for
`XOJITExecutor.framework` being loaded (`dlopen(RTLD_NOLOAD)` returns non-NULL
once it's present), then call `dyld_dynamic_interpose` against its handle. The
runtime API doesn't depend on namespace flattening.

**Concrete recommendation: try `__DATA,__interpose` + `DYLD_FORCE_FLAT_NAMESPACE`
first (simpler). If it doesn't catch the calls, switch to
`dyld_dynamic_interpose` from a constructor.**

### Q3 — Does previewsd strip DYLD_* env vars when spawning XCPreviewAgent?

**Probable answer: no, given the SIP-off + AMFI-off VM, and confirmed by
PreviewsInjection's own DYLD_INSERT_LIBRARIES'd presence.**

Apple's launchd / `posix_spawn` strips `DYLD_*` when the parent is a platform
binary spawning a hardened-runtime child. Both of those gates are removed in
our VM:

- previewsd lives in the dyld shared cache (no on-disk binary; technically a
  platform binary), but the AMFI policy that would strip DYLD env vars for
  platform-binary-spawned children is `amfi_get_out_of_my_way`'d.
- The agent has no hardened-runtime flag (Q1).

The strongest single piece of evidence: **the agent already runs with
`DYLD_INSERT_LIBRARIES=…/PreviewsInjection.framework/…` set, demonstrating
that previewsd's `posix_spawn` call propagates DYLD env vars to the agent in
this VM.** If previewsd were stripping them, the JIT path wouldn't activate
at all — there'd be no PreviewsInjection-injected agent, just the framework
fallback. The `w3-lifecycle-timeline.md` Step 5's JIT-path-symbol-resolution
evidence (lldb `image lookup` finding `PreviewsInjection.__previewsInjection*`
symbols at runtime) confirms the env-var inheritance is live.

So previewsd will propagate whatever DYLD env vars its parent (Xcode) had,
plus whatever it sets itself. The injection point is therefore: **set the env
on Xcode's parent or in launchd's user session BEFORE Xcode launches**.
`launchctl setenv` does the latter cleanly.

### Q4 — Alternatives if all of Q1-Q3 surprise us

If the interposer doesn't fire (most likely cause: namespace binding routes
the agent's intra-XOJITExecutor calls past the interpose entry, even with
`DYLD_FORCE_FLAT_NAMESPACE`), three fallback paths in priority order:

1. **`dyld_dynamic_interpose` from constructor.** Move the interpose
   installation into a `__attribute__((constructor))` in the interposer dylib.
   Poll for `XOJITExecutor.framework` being loaded; once it is, register
   replacements via `dyld_dynamic_interpose(handle, &interposers[0], 2)`. This
   bypasses two-level-namespace shortcuts entirely.
2. **Spawn the agent UNDER lldb (option 2 from `canvas-driving-results.md`).**
   Stop `previewsd` (or never let it spawn the agent), launch the agent
   manually under `lldb -- <agent> <args>`. lldb sees full module list from the
   start (no "No executable module" pathology). Cost: we need to enumerate the
   argv/env previewsd passes — capture it once via `ps -E -www` against a
   running agent, then replay.
3. **In-tree symbol hook via the agent's own GOT.** If we can find the agent's
   GOT entry for `__xojit_executor_write_mem` (it's resolved lazily through
   the GOT on first call), we can write a memory-patch into the agent's GOT
   to redirect the call to our logging trampoline. Requires the agent's
   load address (available via `vm_region_recurse_64` from a helper process
   with `task_for_pid` — `get-task-allow` permits this). This is the
   nuclear-option fallback; multi-day work.

If even (1)-(3) all fail, the address-list sub-task gets re-classified as
Phase-4 production-hardening per `prompts/jit-executor-design.md` §8.4 (which
is where the spike already conditionally places it) and the verdict stands
unchanged.

### Summary

| Concern | Verdict | Evidence |
|---|---|---|
| Hardened runtime blocks DYLD_INSERT? | No | `agent-metadata.txt`: `flags=0x0(none)`, only `get-task-allow` |
| SIP + AMFI block DYLD_INSERT? | No on our VM | `nvram boot-args="amfi_get_out_of_my_way=1"`, `csrutil disable` |
| previewsd strips DYLD env when spawning agent? | No | Agent already has `PreviewsInjection.framework` DYLD_INSERTED |
| Interpose works for `dlopen`'d framework? | Yes with `DYLD_FORCE_FLAT_NAMESPACE`; better via `dyld_dynamic_interpose` | dyld manual + cocomelonc / Mach-O literature |
| Agent's intra-library calls bypass interpose? | Maybe (two-level namespace) | Apple two-level binding documentation; mitigation via flat-namespace or dynamic interpose |

**Net: green light, expect to need `DYLD_FORCE_FLAT_NAMESPACE=1` alongside
`DYLD_INSERT_LIBRARIES`, and have `dyld_dynamic_interpose` as the
constructor-time fallback.**

---

## Provenance

- Session commits: `94c86a1`, `b732128`, `c8056de`, `53915a7`, `b416692`,
  `e0db725` (all on branch `jit-exploration`).
- Snapshot to restore: `/tmp/verify.bundle/snapshots/post-autologin-w3`.
- Preset under modification: `research/vm/Sources/previewsvm/SetupCommand.swift`
  lines 296-680 (`driveXcodePreviewSteps`).
- Agent symbols to interpose: `research/scripts/data/w3/XOJITExecutor-exports.txt`.
- Agent entitlement / signing: `research/scripts/data/w3/agent-metadata.txt`.
- Hot-reload pipeline confirmation:
  `research/scripts/data/w3/16-03g-after-help-canvas-enter.png` (preview
  renders), `research/scripts/data/w3/19-05-lldb-running.png` (lldb attached
  during reload window).
- Design doc whose §2 the capture would refine:
  `prompts/jit-executor-design.md`.
- W3 deliverable doc whose §6 the capture would close:
  `research/scripts/analysis/w3-patch-point-set.md`.

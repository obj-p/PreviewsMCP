# W3 capture — results across four sessions

**Status (after session 4):** ✅ **Capture succeeded.** The
empirical address list of `__xojit_executor_*` calls during a
SwiftUI body-literal hot-reload is captured and committed at
[`w3-writes.interposer.txt`](w3-writes.interposer.txt). The
result is a load-bearing surprise (no `write_mem` calls; full
agent respawn observed) — analysis at
[`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md)
which refines
[`../analysis/w3-patch-point-set.md`](../analysis/w3-patch-point-set.md)
§6 and `prompts/jit-executor-design.md` §2.

Sessions 1-3 explored capture mechanisms that turned out to be
architecturally blocked; session 4 used `LC_LOAD_DYLIB` binary
modification of `XCPreviewAgent` to bypass every prior gate.
The story of how we got here is recorded below.

---

## Sessions 1-3: DYLD_INSERT_LIBRARIES interposer — blocked

**Earlier status:** Built and deployed the interposer dylib + the
launchctl-setenv injection path described in session 1's handoff doc.
The interposer never fires under that injection path. Three
independent barriers, all empirically confirmed in three preset runs,
combine to make the DYLD_INSERT_LIBRARIES injection path
architecturally non-viable for `XCPreviewAgent` under macOS 26.3.1 /
Xcode 26.2.

This is a genuine architectural finding — the handoff doc's Q3
feasibility check ("previewsd strips DYLD_* env when spawning agent? No")
was wrong about Q3 specifically. The previewsd-spawn IS sanitized, in
the sense that previewsd reconstructs the agent's DYLD_INSERT_LIBRARIES
from a hardcoded 5-entry list rather than inheriting and chaining. Two
other unanticipated barriers compound that.

## The three barriers

### Barrier 1 — `launchctl setenv` from SSH doesn't reach admin's GUI launchd session

The preset's "launchctl setenv DYLD_INSERT_LIBRARIES" step succeeds
(`SETENV_OK`, `launchctl getenv` returns the path). The follow-up probe:

```sh
sudo launchctl asuser 501 /bin/bash -lc \
  'echo SHELL_DYLD_INSERT=$DYLD_INSERT_LIBRARIES'
# → SHELL_DYLD_INSERT=     (empty)
```

shows that admin's GUI launchd bootstrap does NOT have our setenv'd
value. The SSH session has its own launchd domain (per-session); the
GUI Aqua launchd bootstrap is a different domain. `launchctl setenv`
without an explicit domain spec writes into the **calling session's
domain**, which for an SSH-launched command is the SSH session,
*not* the GUI session.

Fix-form that would have worked: `launchctl asuser 501 launchctl
setenv DYLD_INSERT_LIBRARIES /tmp/w3-interposer.dylib` (sets in the
asuser-target session). Untried because barriers (2) and (3) below
make it moot anyway.

### Barrier 2 — `open -a Xcode.app` strips DYLD_*

LaunchServices (which `open` talks to) is a privileged boundary and
strips DYLD_* before passing the launch request to launchd. Apple does
this for platform-binary launches to prevent DYLD-based privilege
escalation, with `amfi_get_out_of_my_way=1` an explicit exception only
for the lower-level AMFI policy — LaunchServices' strip happens
earlier and is not gated on AMFI.

Bypass attempt: `sudo launchctl asuser 501 /bin/bash -lc 'env
DYLD_INSERT_LIBRARIES=/tmp/w3-interposer.dylib
DYLD_FORCE_FLAT_NAMESPACE=1
/Applications/Xcode.app/Contents/MacOS/Xcode <project> > /tmp/xcode.stdout
2>&1 &'`. This spawns Xcode in admin's GUI bootstrap directly with our
env, bypassing `open`. The exec succeeds (Xcode comes up and indexes
the project), but the preview pipeline never activates — `pgrep -f
XCPreviewAgent` times out at 90s. The preview pipeline depends on
LaunchServices session context (LSApplicationRegistration handoff to
WindowServer / previewsd's lookup machinery) that direct-exec lacks.
Confirmed in preset run #3.

### Barrier 3 — previewsd reconstructs the agent's DYLD_INSERT_LIBRARIES

Even if we cleared barriers (1) and (2) and got our dylib into
Xcode's env, previewsd would drop it when spawning the agent. The
agent's actual `DYLD_INSERT_LIBRARIES` (captured via
`ps -E -ww -p $AGENT_PID`):

```
DYLD_INSERT_LIBRARIES=
  /Applications/Xcode.app/Contents/Developer/usr/lib/libLogRedirect.dylib:
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/libPlaygrounds.dylib:
  /Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx/libLiveExecutionResultsLogger.dylib:
  /System/Library/PrivateFrameworks/LiveExecutionResultsProbe.framework/LiveExecutionResultsProbe:
  /System/Library/PrivateFrameworks/PreviewsInjection.framework/PreviewsInjection
```

This is a hardcoded 5-entry list. Our `/tmp/w3-interposer.dylib` is
not present — previewsd does not inherit or chain. Same with
`DYLD_FORCE_FLAT_NAMESPACE`: we set it; the agent doesn't have it.

The list's specificity (exact Xcode-internal paths plus exact
PrivateFramework paths) is the diagnostic — these are NOT env-inherited
defaults; they're constructed by previewsd's spawn code per the
Xcode-version it's running.

## What was achieved

Despite the failure to capture, the session produced:

1. **The interposer dylib build infrastructure.** `interposer.c` (at
   `research/scripts/data/w3/interposer.c`) targets all four
   `__xojit_executor_*` exports plus a constructor that logs
   load-time + the loaded process's DYLD_* env. Builds cleanly on
   the guest VM:
   ```
   clang -dynamiclib -arch arm64 -undefined dynamic_lookup \
         -o /tmp/w3-interposer.dylib /tmp/interposer.c
   codesign --force --sign - /tmp/w3-interposer.dylib
   ```
   The `-undefined dynamic_lookup` is load-bearing — the xojit
   symbols are dyld_shared_cache-only.
2. **The 5-entry DYLD_INSERT_LIBRARIES chain captured.** This is
   architecture-level information that the design doc needs: our
   public-layer equivalent must mirror the same five injection points
   if we want feature parity (or document why we don't).
3. **The three-barrier diagnosis** above. Future capture attempts can
   skip the launchctl-setenv path entirely.

## Where to go next: bypass via binary modification

The DYLD-env injection path is closed. The viable fallbacks fall under
"modify a Mach-O on disk", in priority order:

1. **Append LC_LOAD_DYLIB to XCPreviewAgent.** A `~100-LOC` C tool
   reads the Mach-O header, appends a new `LC_LOAD_DYLIB` command
   pointing to `/tmp/w3-interposer.dylib`, rewrites `sizeofcmds`,
   re-codesigns ad-hoc. dyld then loads our dylib at agent startup,
   before any `__xojit_executor_*` references are resolved. The
   interpose table fires. Works regardless of previewsd's env
   handling. The tool is the same shape as the open-source
   `insert_dylib` (3 files, no external deps).

   Edge cases: (a) load-command space may be tight; `insert_dylib`
   handles this by relocating segments if needed. (b) The agent is a
   universal binary (x86_64 + arm64 + arm64e); we only need to patch
   the arm64e slice. (c) AMFI off lets us run modified Apple binaries.

2. **Wrap `libLogRedirect.dylib` inside Xcode.app.** The agent's env
   chain starts with
   `/Applications/Xcode.app/Contents/Developer/usr/lib/libLogRedirect.dylib`.
   Move it to `.real.dylib`, replace it with a stub dylib that has:
   (a) the `__DATA,__interpose` table for the xojit symbols,
   (b) a constructor that `dlopen`s the real
   `libLogRedirect.real.dylib`. dyld loads the stub first (via the
   DYLD_INSERT chain previewsd builds), interpose entries apply, then
   the real library is brought in. No agent-binary modification needed.

   Edge case: the constructor's `dlopen` must precede any
   `libLogRedirect` exports the agent uses; if there are early uses,
   we'd need to re-export specific symbols. The stub being the FIRST
   entry in the chain helps — dyld processes inserts left-to-right.

3. **`dyld_dynamic_interpose` from a constructor in
   PreviewsInjection.** Lower-effort cousin of (2): replace
   `/System/Library/PrivateFrameworks/PreviewsInjection.framework/PreviewsInjection`
   with a wrapper. Same shape as (2) but targets the last entry in
   the chain (PreviewsInjection is what already calls into
   XOJITExecutor, so a wrapper there has the cleanest "before
   xojit_* is invoked" timing). Blocked by SSV: the framework is on
   the signed system volume, read-only even with SIP off. (`-rw`
   remount requires bless-tooling that's out of scope for the spike.)

   Option (2) targets a path inside `/Applications/Xcode.app`, which
   is *outside* SSV — that's why (2) is preferred over (3).

Approach (1) is the cleanest. Approach (2) is the cheapest to retry if
(1) hits a snag. Either gives us the write_mem address list.

---

## Session 4: LC_LOAD_DYLIB binary mod — capture succeeded

The session-3 handoff prescribed `LC_LOAD_DYLIB` binary modification
as the next-attempt fork. Session 4 implemented it: a ~250-LOC C
tool ([`mach-o-add-dylib.c`](mach-o-add-dylib.c)) that appends an
`LC_LOAD_DYLIB` load command to every arm64* slice of a Mach-O
universal binary, plus preset integration that re-codesigns
ad-hoc afterward.

### What was built

- **[`mach-o-add-dylib.c`](mach-o-add-dylib.c)** — Mach-O LC_LOAD_DYLIB
  injector. Patches both `arm64` and `arm64e` slices of the agent's
  fat binary. Validates load-command headroom (88 bytes available; 56
  needed for `/tmp/w3-interposer.dylib`). ~250 LOC, pure C, no deps
  beyond `<mach-o/loader.h>`.
- **[`mem-diff-helper.c`](mem-diff-helper.c)** — second-source
  capture via `task_for_pid` + `mach_vm_region_recurse` +
  `mach_vm_read_overwrite`. Non-invasive (target keeps running, no
  heartbeat timeouts). Snapshots writable regions before/after the
  edit and diffs them.
- **Preset integration** — `research/vm/Sources/previewsvm/SetupCommand.swift`:
  build + deploy both tools, ad-hoc re-codesign with hardcoded
  entitlements plist (the agent's only entitlement is
  `com.apple.security.get-task-allow`), spawn-with-`DYLD_PRINT_LIBRARIES`
  diagnostic.

### What was learned (the two surprises)

1. **The interposer dylib must be a fat binary (arm64 + arm64e).**
   The agent runs as arm64e on Apple Silicon; an arm64-only dylib
   produced dyld errors:
   ```
   '/tmp/w3-interposer.dylib' (mach-o file, but is an incompatible
   architecture (have 'arm64', need 'arm64e'))
   ```
   When dyld rejected our patched arm64e slice, it silently fell back
   to the unmodified arm64 slice — the agent started successfully but
   without our interposer. Fix: `clang -arch arm64 -arch arm64e` for
   the dylib build + `mach-o-add-dylib` patches *every* arm64* slice
   (subtype 0 = arm64, subtype 2 = arm64e) so the LC_LOAD_DYLIB
   survives either arch selection.

2. **The agent process is RESPAWNED across every body-literal edit.**
   The agent's PID changed (1290 → 1403) between the pre-edit
   snapshot and the post-edit snapshot. previewsd kills the existing
   agent and posix_spawns a fresh one to run the JIT-linked edit.
   This contradicts the `[[w3-patch-point-set]]` §2 hypothesis of
   in-place data patching via `mprotect`+`memcpy`+`write_mem`. See
   [`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md)
   for the architectural analysis.

### The captured address list

Full empirical data:
[`w3-writes.interposer.txt`](w3-writes.interposer.txt). 6 calls
across 2 agents:

```
# Agent #1 (pid=1290) — initial canvas render
run_program_wrapper          fn=0xc7ec34140  tid=...
run_program_on_main_thread   fn=0xc7f0fc040  tid=...
run_program_wrapper          fn=0xc7f0fc048  tid=...    (= 0xc7f0fc040 + 8, Swift async ret)

# Agent #2 (pid=1403) — post-edit render (fresh process)
run_program_wrapper          fn=0x95cc34240  tid=...
run_program_on_main_thread   fn=0x95d0fc040  tid=...
run_program_wrapper          fn=0x95d0fc048  tid=...    (= 0x95d0fc040 + 8)
```

`__xojit_executor_write_mem` never fired. `__xojit_run_wrapper`
(the raw `_run_wrapper` export — distinct from
`_executor_run_program_wrapper`) also never fired. Only the
`_run_program_*` dispatch family.

### Acceptance check

The handoff doc's acceptance criterion was "a log file with at least
1 hot-reload-edit's worth of `write_mem(addr, len)` lines plus the
calling-thread ustack (or at minimum the addr+len tuples)." We
captured 0 `write_mem` lines — but the **actual** Apple mechanism
for body-literal edits doesn't use `write_mem`. The empirical
finding answers the underlying question ("which xojit primitives
fire per edit") completely; the W3 sub-task closes with a refined
answer rather than the predicted one.

---

## State files

- [`interposer.c`](interposer.c) — the dylib source. Committed
  master copy. Built as fat (arm64 + arm64e) per the
  session-4 fix.
- [`mach-o-add-dylib.c`](mach-o-add-dylib.c) — LC_LOAD_DYLIB
  injector. Patches all arm64* slices.
- [`mem-diff-helper.c`](mem-diff-helper.c) — task_for_pid +
  mach_vm_read snapshot/diff tool. Second-source capture; the
  data corroborates respawn (large `REGION_ONLY_IN_BEFORE` set
  from the dead pre-edit agent's freed mappings).
- [`w3-writes.interposer.txt`](w3-writes.interposer.txt) — the
  captured `__xojit_executor_*` calls. **6 lines, the W3
  deliverable-#2 result.**
- [`w3-interposer.boot.txt`](w3-interposer.boot.txt) — dyld
  constructor trace per agent process.
- [`w3-mem-diff.txt`](w3-mem-diff.txt) — mach_vm_read snapshot
  diff (1208 lines, dominated by respawn artifacts).
- [`agent-dyld-env.txt`](agent-dyld-env.txt) — the agent's
  hardcoded 5-entry DYLD_INSERT_LIBRARIES chain (captured
  session 2; constant across runs).
- `/tmp/verify.bundle/snapshots/post-autologin-w3` — VM snapshot
  reusable for any further capture attempt. The preset boots
  from this snapshot by default.
- `research/vm/Sources/previewsvm/SetupCommand.swift` — the
  `drive-xcode-preview` preset with full session-4 form:
  build interposer dylib (fat), build mach-o-add-dylib +
  mem-diff-helper on guest, patch the agent's both arm64* slices,
  re-codesign, dyld_print diagnostic, mem-diff snapshot pair.

## Provenance

Session commits:

- `2938154` — session 2: interposer.c + preset modifications.
- `196e4ad` — session 2: dead-end diagnosis + 3-barrier writeup.
- (TBD) — session 4: binary-mod tooling + captured address list.

Verified against macOS 26.3.1, Xcode 26.2 (Build 17C49), running
SIP-off + AMFI-off via the post-autologin-w3 VM snapshot.

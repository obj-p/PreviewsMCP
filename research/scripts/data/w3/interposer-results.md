# DYLD_INSERT_LIBRARIES interposer attempt — results

**Status:** Built and deployed the interposer dylib + the launchctl-setenv
injection path described in the handoff doc's "Continuation prompt" /
"Interposer feasibility check". The interposer never fires. Three
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

## State files

- `interposer.c` — the dylib source. Committed master copy.
- `/tmp/verify.bundle/snapshots/post-autologin-w3` — VM snapshot
  reusable for any further capture attempt.
- `/tmp/w3-interposer-run/` — most recent preset run's artifacts:
  - `w3-writes.interposer.txt` — empty (proves the interpose never
    fired).
  - `w3-interposer.boot.txt` — empty (proves the dylib was never
    loaded anywhere in the user session).
  - screenshots `01-…` through `21-…` — the canvas-driving worked
    perfectly; capture is the only thing that didn't.
- `research/vm/Sources/previewsvm/SetupCommand.swift` —
  `drive-xcode-preview` preset. The interposer build / setenv /
  diagnostics are still in place; future attempts can replace the
  "launchctl setenv" step with a binary-modify step and the rest of
  the preset works unchanged.

## Provenance

Session commit: `2938154` (added interposer.c + preset
modifications). The capture itself produced no output; this doc
records the dead-end with enough detail that the next session can
skip directly to binary modification.

Verified against macOS 26.3.1, Xcode 26.2 (Build 17C49), running
SIP-off + AMFI-off via the post-autologin-w3 VM snapshot.

# W3 — Per-edit `__xojit_executor_write_mem` capture: session 2 handoff

**Status (after session 2):** The DYLD_INSERT_LIBRARIES interposer
approach proposed by session 1's handoff has been built, deployed, and
empirically shown not to work for `XCPreviewAgent` under macOS 26.3.1 /
Xcode 26.2. Three independent barriers stack to block it — see
[`interposer-results.md`](interposer-results.md) for the full
diagnosis. The next attempt fork is **Mach-O binary modification**: add
`LC_LOAD_DYLIB` for our interposer to the agent binary directly,
bypassing all env-injection paths.

The end-to-end Xcode driving infrastructure landed in session 1 still
works; the only thing changing is how the interposer dylib gets into
the agent's address space.

---

## Table of Contents

- [Session 2 review (what was learned)](#session-2-review)
- [Continuation prompt for session 3](#continuation-prompt)
- [Binary-modification feasibility check](#binary-mod-feasibility)

---

## Session 2 review

### What was attempted

Session 1's handoff prescribed a `DYLD_INSERT_LIBRARIES` interposer
dylib + `launchctl setenv` injection (Path A). Session 2 implemented
it:

1. `research/scripts/data/w3/interposer.c` — small dylib (~150 LOC)
   that registers a `__DATA,__interpose` table for the four
   `__xojit_executor_*` exports + a constructor that logs load-time +
   the loaded process's DYLD_* env.
2. The `drive-xcode-preview` preset (commit `2938154`) was modified to:
   build the dylib on the guest (clang with `-undefined dynamic_lookup`
   plus ad-hoc codesign), `launchctl setenv DYLD_INSERT_LIBRARIES` +
   `launchctl setenv DYLD_FORCE_FLAT_NAMESPACE 1`, run the rest of the
   existing canvas-driving flow, then retrieve the capture log.

### What was learned: the 3-barrier diagnosis

The interposer never fires. Three independent barriers, each
empirically confirmed across three preset runs (full data:
[`interposer-results.md`](interposer-results.md)):

1. **`launchctl setenv` from SSH doesn't reach admin's GUI launchd
   session.** SSH sessions have their own launchd domain; `launchctl
   asuser 501 /bin/bash -lc 'echo $DYLD_INSERT_LIBRARIES'` returns
   empty even after our setenv succeeded.
2. **`open -a Xcode.app` strips DYLD_*.** LaunchServices is a
   privileged boundary that drops DYLD_* env vars on the way to
   launchd. Not gated on AMFI; SIP-off + AMFI-off doesn't lift this.
3. **previewsd reconstructs `DYLD_INSERT_LIBRARIES` for the agent
   from a hardcoded 5-entry list.** Captured at
   [`agent-dyld-env.txt`](agent-dyld-env.txt). Our dylib is not in
   the agent's env regardless of how it got into Xcode's env.

Bypassing barrier (2) via `launchctl asuser 501 env
DYLD_INSERT_LIBRARIES=… /Applications/Xcode.app/Contents/MacOS/Xcode`
produced an Xcode without LaunchServices session context — the
preview pipeline didn't activate, `pgrep -f XCPreviewAgent` timed
out. So even if barrier (2) were bypassable, barrier (3) still
blocks the agent's env.

The handoff doc's [Q3 feasibility check][q3] ("previewsd strips DYLD_*
env when spawning agent? No") was wrong. The first-session evidence
that founded Q3 was "`PreviewsInjection.framework` is already
DYLD_INSERTED in the agent" — but it's there because previewsd
**explicitly adds it from a hardcoded list**, not because it's
inherited. Same for the other four entries.

[q3]: #q3-does-previewsd-strip-dyld-env-vars-when-spawning-xcpreviewagent

### Architectural finding (valuable independent of capture)

The agent's hardcoded DYLD_INSERT_LIBRARIES chain has 5 entries:

```
1. .../Xcode.app/.../usr/lib/libLogRedirect.dylib
2. .../Xcode.app/.../libLiveExecutionResultsLogger.dylib
3. .../Xcode.app/.../libPlaygrounds.dylib
4. .../LiveExecutionResultsProbe.framework/LiveExecutionResultsProbe
5. .../PreviewsInjection.framework/PreviewsInjection
```

(Order varies run-to-run; the set is fixed.) Our public-layer
equivalent will need to think about which of these we mirror.
PreviewsInjection is the load-bearing one for the JIT path; the
others support Xcode's live-results telemetry, which our minimum
viable executor doesn't need.

### Session 2 commits

```
TBD  research/scripts/data/w3/: W3 — DYLD_INSERT interposer dead-end, agent env captured
2938154  research/vm/: w3 interposer dylib — swap lldb for DYLD_INSERT capture
```

The preset is in the "second-attempt-ready" state: the interposer
build + setenv + diagnostics are in place, and the canvas pipeline
works end-to-end. A session 3 binary-mod step plugs in just before
"open Package.swift in Xcode".

### Snapshot state on disk

Unchanged from session 1. `post-autologin-w3` remains the launch point.

---

## Continuation prompt

> I'm picking up the JIT-executor research spike at W3 again. The
> mechanism-level closure is settled (commit `94c86a1`). Session 2
> (commit `2938154` + this doc) built the `DYLD_INSERT_LIBRARIES`
> interposer dylib and showed it's architecturally blocked: previewsd
> reconstructs the agent's `DYLD_INSERT_LIBRARIES` from a hardcoded
> 5-entry list, dropping anything we inject. The next-attempt fork is
> **Mach-O binary modification of the agent**.
>
> **Required reading, in order:**
>
> 1. `research/scripts/data/w3/handoff.md` (this file).
> 2. `research/scripts/data/w3/interposer-results.md` — the 3-barrier
>    diagnosis. Pay attention to "Where to go next: bypass via binary
>    modification" — options (1) [LC_LOAD_DYLIB append] and (2)
>    [libLogRedirect.dylib wrapper] are the candidate paths.
> 3. `research/scripts/data/w3/agent-dyld-env.txt` — the captured
>    DYLD_INSERT_LIBRARIES chain. Load-bearing: the wrapper-strategy
>    target list.
> 4. `research/scripts/data/w3/interposer.c` — the dylib source. The
>    `__DATA,__interpose` table is correct; only the injection
>    mechanism needs changing.
> 5. `research/scripts/data/w3/XOJITExecutor-exports.txt` — the four
>    symbols to capture.
> 6. `research/vm/Sources/previewsvm/SetupCommand.swift:driveXcodePreviewSteps`
>    — the preset. The "launchctl setenv DYLD_INSERT_LIBRARIES" step
>    is the one to replace with a binary-mod step (or to keep as a
>    no-op alongside it for the boot.txt diagnostic).
>
> **Single concrete goal:** capture the per-edit write_mem sequence
> via a binary-modification injection. Success = a non-empty
> `w3-writes.interposer.txt` artifact tied to the Hello → Howdy edit.
>
> **Out of scope:**
> - Re-attempting `launchctl setenv` paths. Conclusively blocked at 3
>   barriers.
> - Re-attempting lldb or dtrace. Blocked separately (session 1).
> - SSV-mounted framework wraps (PreviewsInjection.framework lives on
>   the signed system volume; read-only even with SIP off; bless-tool
>   remount is out of scope).
>
> **Recommended path: LC_LOAD_DYLIB append on the agent binary.** The
> agent is at
> `/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/Library/Xcode/Agents/XCPreviewAgent.app/Contents/MacOS/XCPreviewAgent`.
> Xcode.app is in `/Applications` — NOT on SSV — so the binary is
> writable with sudo. The agent is a universal binary
> (x86_64 + arm64 + arm64e); we only need to patch the arm64e slice.
> AMFI off lets the modified binary run.
>
> **Sketch of the binary-mod tool.** ~100 LOC of C:
>
> ```c
> // mach-o-add-dylib.c
> // Append a LC_LOAD_DYLIB command to a Mach-O slice in-place.
> //
> // Usage: mach-o-add-dylib <macho-arch-slice-path> <dylib-path>
> //
> // For a universal/fat binary, slice it first via `lipo -thin arm64e`,
> // patch, then `lipo -create -arch arm64e patched.arm64e ...other-arches`.
> //
> // Algorithm (per Cody Cutrer's `insert_dylib` and similar):
> //   1. Read the slice's mach_header_64 — get ncmds + sizeofcmds.
> //   2. Compute new load command size:
> //        sizeof(dylib_command) + strlen(path) + 1, padded to 8.
> //   3. Verify sizeofcmds + new size <= TEXT segment's fileoff
> //      (otherwise we'd overwrite the start of __TEXT).
> //   4. Append the new dylib_command at offset sizeofcmds:
> //        cmd          = LC_LOAD_DYLIB
> //        cmdsize      = computed
> //        dylib.name   = OFFSET_OF_PATH_FROM_LOAD_COMMAND_START (24)
> //        dylib.timestamp = 1
> //        dylib.current_version = 0x010000
> //        dylib.compatibility_version = 0x010000
> //      followed by the path string + null terminator + padding.
> //   5. Update header: ncmds++, sizeofcmds += new-size.
> //   6. Re-codesign ad-hoc.
> //
> // Reference: https://github.com/Tyilo/insert_dylib (MIT)
> ```
>
> Build this on the guest VM (or on the host and `scp`). Run
> against `/tmp/XCPreviewAgent.patched` (a copy), then `sudo cp` over
> the original (or alongside it and adjust previewsd's expectation —
> previewsd uses an absolute path).
>
> Plug it into the preset between "build + ad-hoc sign interposer
> dylib" (current step 13) and "rebuild test package as library"
> (current step 16). The step needs sudo to write to `/Applications`.
>
> **Acceptance.** `/tmp/w3-writes.log` has at least one
> `write_mem addr=… len=… tid=…` line after the Hello → Howdy edit.
> The boot.txt diagnostic should show the interposer's constructor
> firing in the agent process. Update
> `research/scripts/analysis/w3-patch-point-set.md` §6 with the
> observed address list and `prompts/jit-executor-design.md` §2's
> frequency column.
>
> **If LC_LOAD_DYLIB append fails** (most likely cause: no header
> space for a new load command, or codesign rejects the modification
> even on AMFI off): fall back to libLogRedirect.dylib wrap
> (option 2 in `interposer-results.md`). That dylib's at
> `/Applications/Xcode.app/Contents/Developer/usr/lib/libLogRedirect.dylib`
> — also outside SSV.

---

## Binary-mod feasibility

The three places this could fail and what we know:

### Q1 — Is XCPreviewAgent writable with sudo?

**Yes.** `/Applications/Xcode.app/**` is owned by `root:wheel`,
mode 0755 on directories / 0644 on files. With sudo we can replace
files. Xcode.app is outside SSV (the read-only signed system volume
that hosts `/System`, `/usr`, `/sbin`, `/bin`).

### Q2 — Does AMFI off + SIP off allow running a modified Apple binary?

**Yes.** This is the explicit purpose of the
`amfi_get_out_of_my_way=1` boot-arg + `csrutil disable` combination
the VM is provisioned with. Modified binaries with re-applied ad-hoc
signatures pass kernel CS checks; dyld loads them normally.

The agent has only `com.apple.security.get-task-allow` — no
hardened-runtime flag — so the modified binary doesn't trip
hardened-runtime gates either.

### Q3 — Will the dylib's interpose table fire?

**Yes, with high confidence.** dyld processes
`__DATA,__interpose` tables for every loaded dylib regardless of HOW
it got loaded — `DYLD_INSERT_LIBRARIES`, `LC_LOAD_DYLIB`, or
`dlopen` all produce equivalent interpose-table application. The
xojit symbols are in `XOJITExecutor.framework`, which is loaded into
the agent before any preview rendering, so the interpose entries are
established before any `__xojit_executor_*` call happens.

`DYLD_FORCE_FLAT_NAMESPACE` is still useful (forces dyld to consult
the interpose table for intra-XOJITExecutor calls) — set it via the
existing `launchctl setenv` step *just in case* it propagates this
time (previously did not, but combination with LC_LOAD_DYLIB has no
prior data).

### Q4 — Are there enough free load-command bytes in the arm64e slice?

**Probably.** Modern Apple binaries reserve some slack in the load
commands region for codesigning expansion. The `insert_dylib` tool's
heuristic is to check `min(segment.fileoff)` against
`sizeof(mach_header_64) + sizeofcmds + new_cmd_size`. If too tight,
the tool relocates `__LINKEDIT` to make room — also doable.

To verify without running: `otool -hv <agent>` shows `ncmds` and
`sizeofcmds`; subtract from the first segment's fileoff for the
available bytes. Add a LC_LOAD_DYLIB of size 24 + pad(strlen(path)+1).
For `/tmp/w3-interposer.dylib`, that's 24 + pad(23) = 24 + 24 = 48
bytes. Need ~64 bytes free for safe margin.

### Summary

| Concern | Verdict | Evidence |
|---|---|---|
| Filesystem writability of agent binary? | Yes with sudo | Xcode.app outside SSV |
| AMFI/SIP allow modified Apple binary? | Yes | `amfi_get_out_of_my_way=1` boot-arg, `csrutil disable` |
| dyld processes `__interpose` on LC_LOAD_DYLIB'd dylib? | Yes | dyld manual; this is the standard interposer pattern |
| Enough load-command space in arm64e slice? | Verify with `otool -hv` | small unknown; `insert_dylib` handles tight cases |

**Net: green light. The injection mechanism changes; the interpose
mechanism stays the same. The interposer.c committed to this
directory works unchanged — just inject via a different door.**

---

## Provenance

- Session 2 commits: `2938154` (interposer + preset), TBD (this doc +
  artifacts + writeup).
- Snapshot: `/tmp/verify.bundle/snapshots/post-autologin-w3`.
- Preset under modification (next):
  `research/vm/Sources/previewsvm/SetupCommand.swift` — replace or
  add steps between "build + ad-hoc sign interposer dylib" and
  "open Package.swift in Xcode".
- Architectural finding to feed forward:
  `research/scripts/data/w3/agent-dyld-env.txt`.
- Verified against macOS 26.3.1, Xcode 26.2 (Build 17C49).

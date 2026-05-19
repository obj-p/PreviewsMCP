# W3 — Per-edit `__xojit_executor_*` capture: CLOSED

**Status (after session 4):** ✅ **W3 deliverable #2 closed.** The empirical
address list of `__xojit_executor_*` calls during a SwiftUI body-literal
hot-reload is captured at
[`w3-writes.interposer.txt`](w3-writes.interposer.txt). Architectural
analysis at
[`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md).

The result inverted the static-analysis hypothesis (see
[`w3-patch-point-set.md`](../analysis/w3-patch-point-set.md) §6 for the
refined statement): **Apple uses full agent respawn — not in-place
`write_mem` patching — for body-literal edits.** Only `run_program_*`
primitives fire (3 per agent lifetime, one per render).

This document is now an archive of the four-session journey + a pointer to
the new authoritative artifacts. It is no longer a continuation prompt —
nothing about W3 is open enough to warrant a fresh session.

---

## Table of Contents

- [Final state — where to read what](#final-state)
- [Session-by-session history](#session-history)
- [Reusable artifacts for any follow-up](#reusable-artifacts)

---

## Final state

| Question | Answer | Where it lives |
|---|---|---|
| Is Apple's runtime an LLVM SimpleRemoteEPC executor? | Yes (verified). | [`../analysis/w3-patch-point-set.md`](../analysis/w3-patch-point-set.md) §1 |
| What primitives fire during a body-literal hot-reload? | `run_program_wrapper` + `run_program_on_main_thread` (3 calls / agent / render). No `write_mem`. | [`w3-writes.interposer.txt`](w3-writes.interposer.txt) + [`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md) |
| What patch model does Apple use for body-literal edits? | Full agent respawn — previewsd kills + posix_spawns a fresh agent per edit. | [`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md) "Architectural finding" |
| Does Apple's in-place `mprotect`+`memcpy` mechanism fire? | Not for body-literal edits. Untested for other edit kinds (struct field, function signature, new method). | [`../analysis/w3-patch-point-set.md`](../analysis/w3-patch-point-set.md) §6 "Scope caveat" |
| What does this mean for our design? | Substantially simpler executor: needs `run_program_*` + transport only. No `write_mem`, no W^X dance, no live-call serialization. | [`prompts/jit-executor-design.md`](../../../prompts/jit-executor-design.md) §2 |

The four-session arc is documented at
[`interposer-results.md`](interposer-results.md). Sessions 1-3 explored
DYLD_INSERT_LIBRARIES injection (dead-end at 3 barriers); session 4 used
`LC_LOAD_DYLIB` binary modification of `XCPreviewAgent` to bypass every
prior gate and land the capture.

---

## Session history

### Session 1 — mechanism-level closure (commit `94c86a1`)

Static analysis of `XOJITExecutor.framework` exports/imports +
`PreviewsInjection.framework`. Established the SimpleRemoteEPC architecture
+ the in-place-patch hypothesis. Designed dtrace + lldb capture scripts;
both blocked at signed-binary gates and lldb's "No executable module"
pathology against attached `XCPreviewAgent`.

### Session 2 — DYLD_INSERT_LIBRARIES interposer attempted (commits `2938154`, `196e4ad`)

Built [`interposer.c`](interposer.c) — small dylib with
`__DATA,__interpose` table targeting the four `__xojit_executor_*`
exports. Tried `launchctl setenv DYLD_INSERT_LIBRARIES` injection;
empirically discovered 3 barriers (launchctl-setenv from SSH doesn't
reach GUI launchd session; `open -a` strips DYLD_*; previewsd
reconstructs the agent's DYLD_INSERT_LIBRARIES from a hardcoded 5-entry
list). Captured the agent's actual DYLD chain at
[`agent-dyld-env.txt`](agent-dyld-env.txt).

### Session 3 — LC_LOAD_DYLIB tool + first integration attempts

Wrote [`mach-o-add-dylib.c`](mach-o-add-dylib.c) (LC_LOAD_DYLIB
appender) and [`mem-diff-helper.c`](mem-diff-helper.c)
(`task_for_pid`+`mach_vm_read` snapshot/diff). First runs hit dyld
arch-mismatch ("have 'arm64', need 'arm64e'") — the agent runs as
arm64e, but our interposer dylib was built arm64-only. The agent's
arm64e slice's LC_LOAD_DYLIB was rejected, dyld silently fell back to
the unmodified arm64 slice, and the agent ran without our interposer.

### Session 4 — capture succeeded ✅

Fixed by building the interposer as a fat dylib (`-arch arm64 -arch
arm64e`) and patching every arm64* slice (subtype 0 = arm64 + subtype
2 = arm64e). Re-codesigned ad-hoc with hardcoded entitlements plist
(`com.apple.security.get-task-allow=true`).

Result:

- dyld loads `/tmp/w3-interposer.dylib` at agent startup
  ([`w3-interposer.boot.txt`](w3-interposer.boot.txt)).
- Constructor fires; interpose table applies.
- Interposed calls captured in
  [`w3-writes.interposer.txt`](w3-writes.interposer.txt) — 6 calls
  across 2 agents (the pre-edit and post-edit agents have different
  PIDs).
- **No `write_mem` calls.** Apple uses respawn-per-edit, not in-place
  patch.

Updated docs:

- [`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md) — new authoritative empirical-findings doc.
- [`../analysis/w3-patch-point-set.md`](../analysis/w3-patch-point-set.md) §6 — empirical refinement of the mechanism question.
- [`prompts/jit-executor-design.md`](../../../prompts/jit-executor-design.md) §2 — simplifies the design accordingly.

---

## Reusable artifacts

The following are reusable for any future capture against different edit
kinds (struct field, function signature, new method, etc.):

- [`interposer.c`](interposer.c) — the dylib source. Logs every
  `__xojit_executor_*` call to `/tmp/w3-writes.log`. Reusable
  unchanged.
- [`mach-o-add-dylib.c`](mach-o-add-dylib.c) — LC_LOAD_DYLIB injector.
  Patches arm64 + arm64e slices. Reusable unchanged.
- [`mem-diff-helper.c`](mem-diff-helper.c) — mach_vm_read snapshot
  helper. Second-source capture; corroborates respawn observations.
- `research/vm/Sources/previewsvm/SetupCommand.swift:driveXcodePreviewSteps`
  — the `drive-xcode-preview` preset. To capture a different edit
  kind, modify the `sed` step (currently `s/Hello/Howdy/g`) to make
  the desired source change, then re-run with
  `--restore-from post-autologin-w3`.

### How to run another capture

```sh
cd research/vm
./build.sh debug
rm -rf /tmp/w3-interposer-run
.build/debug/previewsvm setup /tmp/verify.bundle \
    --preset drive-xcode-preview \
    --transport vnc \
    --restore-from post-autologin-w3 \
    --output-dir /tmp/w3-interposer-run
# ~6 min wall time. Output at:
#   /tmp/w3-interposer-run/w3-writes.interposer.txt
#   /tmp/w3-interposer-run/w3-interposer.boot.txt
#   /tmp/w3-interposer-run/w3-mem-diff.txt
```

### Suggested follow-up captures

In priority order (highest expected variance from the body-literal baseline first):

1. **Struct field change** — `struct Foo { let x: Int }` → `struct Foo { let x: Int; let y: Int }`. Tests whether structural ABI changes trigger `write_mem` or remain respawn-only.
2. **New SwiftUI `@State` property** — adding a new `@State var counter = 0`. Tests whether SwiftUI's state machinery uses in-place patching for state additions.
3. **New file** — adding a sibling `.swift` file referenced from `ContentView.swift`. Tests multi-file edits.
4. **Function signature change** — changing a helper function's parameter list. Tests cross-symbol re-linking.

If any of these triggers `write_mem`, document at
[`../analysis/w3-empirical-capture.md`](../analysis/w3-empirical-capture.md)
"Scope caveat" with the observed addresses.

---

## Provenance

- Session commits: `94c86a1` (session 1 mechanism), `2938154` + `196e4ad` (sessions 2 + 3), TBD (session 4).
- Verified against macOS 26.3.1, Xcode 26.2 (Build 17C49), running SIP-off + AMFI-off via the `post-autologin-w3` VM snapshot.

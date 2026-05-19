# W3 empirical capture — per-edit `__xojit_executor_*` address list

**Source data:** [`research/scripts/data/w3/w3-writes.interposer.txt`](../data/w3/w3-writes.interposer.txt) (the raw interposer log), [`research/scripts/data/w3/w3-interposer.boot.txt`](../data/w3/w3-interposer.boot.txt) (dyld load + env trace), [`research/scripts/data/w3/w3-mem-diff.txt`](../data/w3/w3-mem-diff.txt) (mach_vm_read snapshot diff).

**Verified-against:** macOS 26.3.1, Xcode 26.2 (Build 17C49), running SIP-off + AMFI-off in the research VM. Captured via the `drive-xcode-preview` preset's session-3 form: `LC_LOAD_DYLIB` injection into both arm64 + arm64e slices of `XCPreviewAgent` (binary mod via `mach-o-add-dylib.c`), interposer dylib built fat (arm64 + arm64e) at `/tmp/w3-interposer.dylib`, ad-hoc re-codesigned, dyld loads the interposer at agent startup (constructor logs confirm).

**Scope of this capture.** One edit kind only: a body-literal `Hello` → `Howdy` change in a SwiftUI `Text(...)` inside a library-target `#Preview` block. Other edit kinds (struct field, function signature, new method, etc.) were not exercised and may use different mechanisms.

---

## TL;DR

For a SwiftUI body-literal hot-reload edit, Apple's runtime fires **only `run_program_*` primitives — never `__xojit_executor_write_mem`**. The agent is **respawned end-to-end on every edit** (different PID before vs after); there is no in-place patch of the resident pseudodylib. The mechanism hypothesis from [`w3-patch-point-set.md`](w3-patch-point-set.md) §2 — "option (a) in-place `mprotect`+`memcpy`" — is **incorrect for this edit kind**.

This simplifies the design doc dramatically. Our equivalent executor needs:

1. A `SimpleRemoteEPC`-style executor exposing `run_program_on_main_thread` / `run_program_wrapper`.
2. A spawn-per-edit lifecycle (host kills + relaunches agent on every source change).

It does **not** need:

3. `write_mem` against the in-memory pseudodylib's data pages.
4. The W^X `mprotect`+`memcpy` dance.
5. Witness-table / GOT / TLV slot rewriting at the agent.

Items (3)-(5) may still apply for OTHER edit kinds we haven't captured; until further evidence, treat them as Phase-4 production-hardening work only.

---

## Raw capture (per-agent timeline)

Two agents observed in the capture. PID 1290 was alive during canvas activation; PID 1403 spawned after the source edit.

```
# Agent #1 — initial canvas render (pid=1290)
t=0       ns  loaded     pid=1290  exe=…/XCPreviewAgent
t=251     ms  run_program_wrapper          fn=0xc7ec34140  tid=0x16dd47000
t=257     ms  run_program_on_main_thread   fn=0xc7f0fc040  tid=0x16deeb000
t=257     ms  run_program_wrapper          fn=0xc7f0fc048  tid=0x1fc86b100

# (Hello → Howdy edit at t≈87 s relative to agent #1's load.)

# Agent #2 — post-edit render (pid=1403, spawned by previewsd)
t=86.2    s   loaded     pid=1403  exe=…/XCPreviewAgent
t=86.5    s   run_program_wrapper          fn=0x95cc34240  tid=0x16d7cb000
t=86.5    s   run_program_on_main_thread   fn=0x95d0fc040  tid=0x16d857000
t=86.5    s   run_program_wrapper          fn=0x95d0fc048  tid=0x1fc86b100
```

(`t=` values rebased to agent #1's load time. Absolute timestamps in the raw log.)

### Call-pair shape

Each agent's lifetime shows exactly **three** entries in the interpose log:

1. **`run_program_wrapper`** — the initial JIT bootstrap call. Sets up the
   executor's call frame for a function the host has just JIT-linked.
2. **`run_program_on_main_thread`** — main-thread invocation of the body's
   entry point.
3. **`run_program_wrapper`** — paired with (2), 8 bytes after the
   entry-point fn (`fn₂ + 8 == fn₃`). This is the Swift async ABI's
   `_ret` / continuation entry point.

The 8-byte offset between calls (2) and (3) is the Swift async ABI signature:
emit-time, swiftc generates a paired `__swift_async_entry` + `__swift_async_ret` for each async function, exactly 8 bytes apart in the pseudodylib's `__TEXT` section. The host invokes the entry; the agent's async continuation hits the ret.

### What's notably absent

- **No `__xojit_executor_write_mem` calls in either agent's lifetime.** Zero, across canvas open + hot-reload. The mechanism that w3-patch-point-set.md §2 hypothesized as "the patch primitive" does not fire for body-literal edits.
- **No `__xojit_run_wrapper` calls.** The agent uses only the higher-level `_executor_run_program_*` family — never the raw `_run_wrapper` exported alongside.
- **No process-shared region patches.** The mem-diff snapshots are dominated by `REGION_ONLY_IN_BEFORE` entries (the dead agent's freed mappings) and a small set of byte-level diffs in surviving regions (kernel-managed shared regions, dyld_shared_cache). Consistent with full respawn, not in-place patch.

---

## Architectural finding: Apple's body-edit mechanism is respawn, not patch

The agent's PID changed across the source edit (1290 → 1403). Both agents observed the same call pattern (3 `run_program_*` calls per lifetime). previewsd posix_spawn'd a fresh agent for the post-edit render; it did not patch the original.

This contradicts the [`w3-patch-point-set.md`](w3-patch-point-set.md) §1-5 hypothesis (in-place patch via host-side ORC → agent-side `write_mem`). The hypothesis was derived from static analysis of XOJITExecutor's exports + imports — the *primitives* are all there for in-place patching, but Apple's runtime *chooses* to respawn instead.

Plausible reasons:

- **Simpler.** Respawn is one posix_spawn + a fresh XPC handshake. In-place patching requires the host's ORC to compute exact byte deltas against the live agent's address space (complicated by ASLR, JIT-allocated mappings, and Swift's relocation-laden link model).
- **Correctness-by-construction.** A fresh process can't have stale state from the pre-edit JIT'd code (objects, observers, runtime-registered protocols, async continuations on the stack). Respawn guarantees the new code runs from a clean slate.
- **Cost-of-spawn is small.** Posix_spawn + dyld_shared_cache binding for the agent's lean Mach-O takes ~80-200 ms on Apple Silicon. For an interactive preview-edit workflow, this is well under the perception threshold.

The remote-EPC `run_program_*` primitives are still used — once per render — because the host needs to invoke the JIT'd body in the agent's address space. They are not the patch primitive; they are the **dispatch** primitive.

---

## Implications for `prompts/jit-executor-design.md`

The design doc's §2 patch-point spec assumed in-place patching. With this finding, that spec simplifies to:

- **Per-edit pipeline.** Host JIT-links the new `.o` against the agent's symbol map → kills the previous agent → spawns a fresh agent → invokes the new entry point via remote-EPC `run_program_on_main_thread`. No data-section patching.
- **Patch-point set per body-literal edit.** Empty at the agent-mutation level; the entire JIT'd code is fresh-loaded in the new agent's process.
- **Concurrency.** No in-flight serialization problem — the old agent is dead before the new one runs. The old agent's call stack and references are gone with its process.

For the design doc's §5 "Public-layer analogue checklist," our equivalent agent's surface area is even smaller than the W3 analysis claimed: we need an `executor_run_program_on_main_thread` + `executor_run_program_wrapper` + an XPC/socket transport — and that's it. No `executor_write_mem` (we don't need the patch primitive if we always respawn).

**This is a Verdict-#1-friendly simplification.** "Build the same architecture Apple ships" gets cheaper.

### What this does NOT close

The session-4 capture exercised exactly one edit kind. Session 5
extends the capture across four edit kinds; see below.

---

## Session-5 multi-edit capture — respawn-only generalizes

A follow-up session exercised four edit kinds sequentially in a
single run, with two extra interpose families added: PreviewsInjection
JIT-link entry points (Swift-mangled — `__previewsInjectionJITLinkEntrypoint`
+ `__previewsInjectionPerformFirstJITLink`) + XPC
`xpc_connection_send_message{,_with_reply_sync}`. The hypothesis was
that one of these other edit kinds — particularly the structural
`@State` add — might exercise `__xojit_executor_write_mem` (the
in-place patch primitive) instead of respawn. **It does not.**

| # | Edit | PID change | write_mem? | run_program calls | mem-diff `REGION_ONLY_IN_BEFORE` |
|---|---|---|---|---|---|
| 1 | body-literal-same-file (`World`→`Earth` in ContentView.swift) | 1307→1411 | 0 | 3 | 89 |
| 2 | body-literal-cross-file (`Hello`→`Howdy` in Model.swift, read via `greeter.prefix`) | 1411→1495 | 0 | 3 | 122 |
| 3 | add-method (new `func decorate(_:)` in ContentView) | 1495→1579 | 0 | 3 | 120 |
| 4 | add-state (new `@State private var counter` + Text reading it) | 1579→1659 | 0 | 3 | 123 |

Five total agent PIDs (initial + four respawn-per-edit), 15 total
`run_program_*` calls — exactly 3 per agent, matching the body-literal
pattern.

Notably **zero** of these:

- `__xojit_executor_write_mem` — the in-place patch primitive is
  dormant across all 4 edit kinds, including the most structural one.
- `__previewsInjectionJITLinkEntrypoint` — see "What's also notably
  absent" below.
- `__previewsInjectionPerformFirstJITLink` — same.
- `xpc_connection_send_message` / `xpc_connection_send_message_with_reply_sync`
  — the agent's XPC traffic does not go through the C `xpc_*` API.
  It uses Swift wrappers (the `XOJITExecutor` class methods that take
  `OS_xpc_object` parameters — exported as
  `_$s13XOJITExecutorAAC10connection…` per the framework's exports).
  To capture XPC content we'd need to interpose at the Swift-symbol
  level.

The mem-diff `REGION_ONLY_IN_BEFORE` counts (~90-123 per edit) are
the unmistakable signature of process replacement: ~120 of the
agent's writable VM regions disappear and ~120 fresh ones appear at
the same virtual addresses (the same Mach-O slices get re-mmap'd at
the same ASLR'd bases in the new process). In-place patching would
produce zero `REGION_ONLY_IN_BEFORE` entries and a much smaller set
of byte-level `DIFF`s. We don't see that.

**Universalized conclusion for macOS 26.2 / Xcode 26.2:** for every
edit kind in our test matrix, Apple's runtime is a respawn-only
system. The Mach-O surfaces enumerated in §3 of
[`w3-patch-point-set.md`](w3-patch-point-set.md) remain the
static-analysis universe of *what JITLink could patch* — but Apple's
runtime exercises **zero** of them per edit.

### What's also notably absent: PreviewsInjection JIT-link calls

The 0 `pi_jit_link_entrypoint` count across 5 agents is mildly
surprising — the function name reads like "the agent's main JIT-link
entry point." Most plausible interpretation: it IS the entry, but
only on cold start (the agent's `main()` calls it once into the EPC
server loop). Our `__DATA,__interpose` table fires on cross-image
calls only; intra-binary calls inside the agent's own `main` resolve
through the GOT without going through the interpose entry. So we'd
miss it.

To confirm: function-prologue hook (write the first bytes of the
function to jump to our trampoline) rather than via
`__DATA,__interpose`. Out of scope for this spike; the respawn-only
conclusion holds either way.

### What would falsify "respawn-only"

If a future macOS/Xcode release optimizes the hot-reload path with an
in-place fast-path, we'd want to re-run the preset with the same
edit-kind matrix. Additional edit kinds worth trying:

- Removing a stored property (Swift ABI shrinks).
- Changing a function signature.
- Adding a closure capture or `@escaping` marker.
- Conformance addition (new protocol extension).
- New file with a public type.

Any `write_mem` hit would tell us Apple has layered an in-place
fast-path above the respawn baseline. Document per-edit-kind dispatch
in this file's "Session-N" section if/when that happens.

---

## Provenance

- Raw interposer log: [`research/scripts/data/w3/w3-writes.interposer.txt`](../data/w3/w3-writes.interposer.txt) (session-5 form: 20 lines, 15 `run_program_*` calls across 5 agents — initial + 4 respawn-per-edit).
- dyld boot trace: [`research/scripts/data/w3/w3-interposer.boot.txt`](../data/w3/w3-interposer.boot.txt) (5 `loaded` + env events).
- Per-edit mem-diff snapshots:
  - [`research/scripts/data/w3/w3-mem-diff-e1.txt`](../data/w3/w3-mem-diff-e1.txt) — body-literal-same-file (6492 lines: 89 REGION_ONLY_IN_BEFORE + 6400 DIFF).
  - [`research/scripts/data/w3/w3-mem-diff-e2.txt`](../data/w3/w3-mem-diff-e2.txt) — body-literal-cross-file (1393 lines: 122 + 1268).
  - [`research/scripts/data/w3/w3-mem-diff-e3.txt`](../data/w3/w3-mem-diff-e3.txt) — add-method (1244 lines: 120 + 1121).
  - [`research/scripts/data/w3/w3-mem-diff-e4.txt`](../data/w3/w3-mem-diff-e4.txt) — add-state (1212 lines: 123 + 1086).
- Capture infrastructure: `research/scripts/data/w3/interposer.c` (the dylib — now with 8 interpose entries: 4 xojit + 2 XPC + 2 PreviewsInjection-Swift-mangled), `research/scripts/data/w3/mach-o-add-dylib.c` (the binary-mod tool), `research/scripts/data/w3/mem-diff-helper.c` (mach_vm_read helper).
- Preset that ran the capture: `research/vm/Sources/previewsvm/SetupCommand.swift:driveXcodePreviewSteps` (session-5 form has 4 sequential sed/cat edits + per-edit mem-diff pairs).
- Session writeup: [`research/scripts/data/w3/interposer-results.md`](../data/w3/interposer-results.md).
- Design doc (whose §2 this refines): [`prompts/jit-executor-design.md`](../../prompts/jit-executor-design.md).

# W3 — Patch-point set

**Workstream:** W3 deliverable #2 per `prompts/jit-executor-research.md` →
"Workstreams" section. The single most valuable artifact of the entire spike per
the scope doc — tells us *which Swift-ABI surfaces our own JIT executor must
reach* to achieve equivalent override semantics.

**Status:** Mechanism level: closed. Address-list level: requires a follow-up
runtime capture (described in "Pre-implementation runtime confirmation" below).
This document is structured to feed directly into `prompts/jit-executor-design.md`
once that is written.

**Verified-against:** macOS 26.3.1, Xcode 26.2 (Build 17C49), PreviewsInjection +
XOJITExecutor as resident in dyld_shared_cache on that platform.

---

## TL;DR

**Apple's runtime is not a self-contained patch engine — it's an LLVM
`SimpleRemoteEPC` executor.** Patch *decisions* are made host-side (in Xcode /
`previewsd`'s LLVM ORC instance); the agent-side
`XOJITExecutor.framework` exposes a remote-memory-write primitive
(`___xojit_executor_write_mem`) and the host calls it over XPC to apply each
patch. The patch mechanism is therefore **option (a) from
`prompts/jit-executor-findings.md` ("Phase 2.1 stretch goal" outcome):
in-place byte-level data patch of the protocol-witness-table (PWT) slot, via
`mprotect`+`memcpy` against a writable mapping of the in-memory pseudodylib's
data pages.** Option (b) (`JITDylib::replace` / per-conformance JITDylib
swap) is *not* Apple's primary mechanism — there is no `replace`-style export
on either framework, and the patch path's necessary primitives
(`_mprotect`, `_mach_vm_map`, `_memcpy`, `_memmove`) are all present in
XOJITExecutor's imports.

The full patch-point ADDRESS LIST — which specific PWT slots / GOT entries /
TLV initializers get rewritten on a given preview edit — requires runtime
capture during an actual hot-reload, which is the pre-implementation TODO.

---

## What the spike scope asked for, mapped to what was achievable

The spike scope (`prompts/jit-executor-research.md:282-285`) called for:

> **The patch-point set.** Before/after diffs of the agent's loaded image at
> JIT-link time: which vtable slots changed, which witness-table entries
> changed, which symbol stubs were rewritten.

What was achievable without driving a real preview session (the spike's
verdict + design doc both treat this as bounded post-spike work):

| Spike-scope item | Achievable from static + observed-runtime analysis? |
|---|---|
| Mechanism family used (in-place data patch vs JITDylib replace vs other) | **Yes, closed.** See "Mechanism", below. |
| Locus of the patch-decision logic (host-side ORC vs agent-side runtime) | **Yes, closed.** See "Architectural split", below. |
| Specific Swift-ABI surfaces touched (PWT, vtable slot, GOT entry, stub, TLV bootstrap, …) | **Partially.** The set of POSSIBLE surfaces is fully enumerated by JITLink's relocation kinds (W2 POC exercised all of them — see `prompts/jit-executor-findings.md` Phase 2.x results). Which subset Apple's runtime *actually patches per edit* needs runtime capture. |
| Concrete address list per edit kind | **No.** Requires runtime capture. |
| Concurrent-patch sequencing (live-call serialization) | **Mechanism inferred, not yet observed.** See "Concurrency", below. |

The first three items are what the architecture / design doc actually needs.
The last two are tuning-level details that get answered the first time the
implementation tries a real edit.

---

## 1. Architectural split: where patches are computed vs applied

The spike's most consequential single finding for the patch model: **Apple's
runtime is an LLVM `SimpleRemoteEPC` executor.** This is not a paraphrase — the
function symbols are literal LLVM remote-EPC vocabulary:

```
XOJITExecutor.framework  exports:

  ___xojit_executor_write_mem
  ___xojit_executor_run_program_on_main_thread
  ___xojit_executor_run_program_wrapper
  ___xojit_run_wrapper
```
(`research/scripts/data/w3/XOJITExecutor-exports.txt`).

Compare with LLVM's open-source `llvm-jitlink-executor` helper tool, which
exports `__llvm_jitlink_executor_write_memory`,
`__llvm_jitlink_executor_run_wrapper`, `__llvm_jitlink_executor_run_program`
through the same `SimpleRemoteEPC` protocol. Apple renamed the prefix (`xojit_`
instead of `llvm_jitlink_`) and substituted XPC for socket as the transport,
but the wire-level shape is identical.

What this means for the patch model:

- **Host-side (Xcode / previewsd)** runs the actual LLVM ORC `LLJIT` instance.
  When a preview edit produces a new `.o`, ORC:
  1. Loads the `.o` into an `ObjectLinkingLayer`.
  2. Resolves relocations against the agent process's symbol map (which the
     agent has reported back over XPC via the executor's
     `lookupSymbolsRequest` family — also part of `SimpleRemoteEPC`).
  3. Decides which addresses in the agent's memory need to be written with
     what bytes (the JITLink "allocate finalize step").
- **Agent-side (XCPreviewAgent)** is just a remote process the host pokes:
  1. Receives `WriteMemory(addr, bytes)` commands via `___xojit_executor_write_mem`.
  2. Receives `RunProgram(fnAddr, args)` commands via
     `___xojit_executor_run_program_on_main_thread` and friends.
  3. Reports any unresolved symbols back over the XPC channel.

This is a substantial architectural finding that did not get captured in the
verdict doc — the verdict said "build the same architecture Apple ships." With
the split now visible: **"the same architecture" includes the host-side ↔
agent-side cleavage.** Our `prompts/jit-executor-design.md` should mirror it.

Implications for our design:

- The agent process owns very little. It needs `XOJITExecutor`-equivalent
  primitives (allocate writable pages, write memory, flip W^X, register GDB JIT
  interface, run program on main thread) — a few hundred LOC of glue.
- The host process owns the LLVM ORC instance, the relocation logic, the
  symbol-cache, and the patch-decision policy (which witness-table slot to
  overwrite vs which JITDylib to extend).
- The wire protocol is the LLVM `SimpleRemoteEPC` interface, exactly. We don't
  invent it.

---

## 2. Mechanism: in-place data patch via `mprotect`+`memcpy`

XOJITExecutor's imports include all the primitives needed for in-place patching
of already-allocated, already-mapped JIT memory:

```
_mach_vm_map        # allocate JIT-eligible page mappings (the W^X dance dst)
_mprotect           # flip writable/executable protections
_memcpy
_memmove
```
(`research/scripts/data/w3/XOJITExecutor-imports.txt`).

`PreviewsInjection.framework` (which sits one layer above XOJITExecutor)
imports `_memcpy` + `_memmove` but **does not** import `_mprotect` or
`_mach_vm_map` — confirming the W^X juggling is encapsulated inside
XOJITExecutor's `write_mem` implementation, not exposed to PreviewsInjection's
higher-level code (`research/scripts/data/w3/PreviewsInjection-imports.txt`).

There is **no `replace`, `swap`, `relink`, `patch`, or atomic-rewrite symbol**
on either framework's export surface (grep on
`{XOJITExecutor,PreviewsInjection}-exports.txt`). That rules out Apple shipping
a JITDylib-replacement mechanism as the primary patch path — option (b) from
the Phase 2.1 stretch-goal hypothesis. The remote-EPC vocabulary is the entire
patch surface.

The pseudodylib hook (`__dyld_is_pseudodylib` — see Q6 findings) is orthogonal
to patching; its job is to keep dyld's image-list scanners from misidentifying
in-memory JIT'd code as normal dylibs. It does not participate in the patch
mechanism.

**Mechanism conclusion (W3 deliverable #2, mechanism-level):**

Apple's preview-edit patch is implemented as in-place writes into the agent's
already-mapped pseudodylib memory, driven by the host's ORC instance over the
`SimpleRemoteEPC` wire protocol. Each `write_mem` command:

1. Receives `(targetAddress, bytes)`.
2. Calls `_mprotect(page, PROT_WRITE)` (or the platform-equivalent — on Apple
   Silicon this is `pthread_jit_write_protect_np(false)` for `MAP_JIT` regions,
   plus `os_thread_self_restrict_tpro_to_rw()` on the strictest hardening
   level).
3. `_memcpy(targetAddress, bytes, len)`.
4. Re-protects (`pthread_jit_write_protect_np(true)` / `_mprotect(..., PROT_EXEC)`).

The decision *which* bytes to write to *which* addresses is made host-side. For
a SwiftUI `body` literal edit, the decision is: "overwrite the function-pointer
slot in the PWT for the `body` requirement with the address of the newly
JIT-linked function". That single pointer-width store is sufficient to
redirect future calls through the witness table.

---

## 3. Apple-side Swift-ABI surfaces this mechanism reaches

By "reaches" we mean: surfaces that `XOJITExecutor::write_mem` can validly
target with the right pointer-width data. These are *not* edit-specific (which
slots get written depends on what changed); they're the universe of surfaces a
JIT-link can in principle touch. The W2 POC has already validated public LLVM
JITLink + Swift correctly emits/relocates each of them, which is why we know
the mechanism *reaches* them and not just lists them.

| Surface | Mach-O section | Swift / runtime role | Patch shape on edit |
|---|---|---|---|
| Protocol witness table (PWT) entry | `__DATA_CONST,__const` (read-only) → has to be remapped writable | Function-pointer slot per protocol requirement, dispatched by `swift_call_witness_*`. | Single pointer-width store at the slot's runtime address. |
| Class vtable slot | `__DATA_CONST,__const` (class-metadata vector) | Function-pointer per overridable method, dispatched by class metadata. | Single pointer-width store, same shape. |
| GOT entry (`__DATA_CONST,__got`) | `__DATA_CONST,__got` | External-symbol indirection cell (e.g. for cross-image runtime function references). | Single pointer-width store, redirects callers using the GOT. |
| Symbol stub (`__TEXT,__stubs`) | `__TEXT,__stubs` | Lazy-resolved jump-to-callable trampoline. | Stub bytes overwritten (typically just the `B` target). For SwiftUI hot-reload, less common than PWT — most preview-thunk dispatch is witness-mediated, not stub-mediated. |
| Async function pointer | `__TEXT,__swift_as_entry` / `__TEXT,__swift_as_ret` | Continuation entry / return points for async-CC functions. | Pointer-width store into `as_entry` slot — *if* the edit replaces an `async` body. Async-CC ABI's two-section emission (entry + ret) means the patch may touch both. POC Phase 2.3 exercised this. |
| TLV initializer | `__DATA,__thread_vars` + `__DATA,__thread_data` | Per-thread storage init function. | Patch the `tlv_init` slot — *if* the edit changes module-level state initialization. POC Phase 2.2 exercised this. |
| `swift_once` global-init function | `__DATA,__data` (the once function pointer) + `__DATA,__bss` (the once token) | Lazy module-level `let`/`var` initialization. | Patch the `_…_WZ` initializer pointer (the addressor's reference). Combined with resetting the once-token to re-fire. POC Phase 2.2 exercised this. |
| ObjC selref slot | `__DATA,__objc_selrefs` | SEL pointer slot, populated at image load via `sel_registerName`. | Patch the slot with the new canonical SEL address — *if* the edit introduces a previously-unused selector. POC Phase 2.2.5 exercised this via a custom `ObjCSelrefPlugin`. |
| ObjC class registration | `__DATA,__objc_classlist` | Class struct (registered via `objc_registerClassPair` / `_objc_realizeClassFromSwift`) | Less common in pure SwiftUI bodies, but possible. POC Phase 2.3 surfaced this as an open gap (a missing plugin we'd write). Apple's stack does not import `objc_register*` in PreviewsInjection — likely they handle ObjC class registration host-side and only patch the class slot. |

The "patch shape" column is the load-bearing artifact. For our equivalent
implementation, each row collapses to "one or more pointer-width
`write_mem` calls at addresses produced by ORC's relocation resolution."

---

## 4. Concurrency: how live calls are serialized against patching

XOJITExecutor's exports include `___xojit_executor_run_program_on_main_thread`
(`research/scripts/data/w3/XOJITExecutor-exports.txt`). The "on_main_thread"
suffix is significant — JIT'd preview entry points run on the agent's main
thread (which is also the NSApplication run loop's thread). This is *not* an
arbitrary choice; it gives the patch mechanism a serialization guarantee.

The implied serialization model:

- All preview-rendering work runs on the main thread (the SwiftUI / NSApplication
  thread).
- The XPC handler that processes `__previewsInjectionJITLinkEntrypoint` and
  ultimately calls `write_mem` is dispatched off the main thread (XPC
  connections deliver on private queues), but the *application* of the
  patch — specifically, the call into XOJITExecutor's write_mem — can be
  marshaled onto the main thread before applying.
- Between the patch landing and the next preview body invocation, all
  function-pointer reads (PWT slot read, vtable slot read, GOT entry read) are
  pointer-width atomic on AArch64 — so even if the patch and a call happen
  concurrently, the call sees either the old or the new pointer, never a torn
  composite.

This matches the "Concurrent-patching correctness" uncertainty from
`prompts/jit-executor-findings.md` resolution: "PWT in-place patch serializes
via atomic pointer-width writes; live call sites reached only through
indirections we control."

What we *don't* know without runtime capture:

- Whether Apple in practice marshals the patch onto the main thread, or just
  relies on the atomic-pointer-write guarantee and accepts that an in-flight
  call may "see" the old function.
- Whether there's an explicit "drain in-flight previews" handshake before
  applying patches (e.g., the `cancelUpdate` async method on `EntryPoint` —
  visible in `PreviewsInjection-exports.txt:0x0002A030` — suggests yes).

These can be answered from runtime traces; they are tuning-level decisions for
our implementation, not architectural gates.

---

## 5. Public-layer analogue checklist (what our equivalent needs)

Direct mapping from Apple's pieces to what `prompts/jit-executor-design.md`
will need to specify:

| Apple piece | Our public-layer analogue | Sizing |
|---|---|---|
| XOJITExecutor framework (Swift class + C-style write_mem/run_program ABI) | Our own thin Swift+C executor library: wraps `llvm::orc::SimpleRemoteEPCServer`, exposes equivalent `executor_write_mem` / `executor_run_program_on_main_thread` C entrypoints, plus `JITDylibHandle`-equivalent value type. | Small (~300 LOC). The remote-EPC server class is provided by LLVM. |
| `mach_vm_map` allocation for JIT-eligible memory | Same call. `MAP_JIT` flag on Apple Silicon; standard `mmap(PROT_NONE)` + `mprotect` elsewhere. LLVM's `JITAllocator` already exposes this. | Trivial. |
| `mprotect`+`memcpy` W^X dance inside write_mem | `pthread_jit_write_protect_np` on Apple Silicon (or `os_thread_self_restrict_tpro_to_rw()` on the strictest hardening level). Wrapped inside our `executor_write_mem`. | Trivial. Standard JIT pattern. |
| XPC transport (XOJITExecutor uses XPC; `_$s13XOJITExecutorAAC10connection8XPCConnVAA15TerminationResultOcfc` etc.) | LLVM's `SimpleRemoteEPC` defaults to socket/pipe. For our deployment we can use either — Unix domain socket for local agent process; XPC if shipping inside a macOS host app; gRPC over TCP for iOS device-side. | Trivial. LLVM's SimpleRemoteEPC supports pluggable transports. |
| GDB JIT debug interface (`___jit_debug_register_code`, `_llvm_orc_registerJITLoaderGDBAllocAction`) | Same. The LLVM `DebuggerSupportPlugin` is the same plugin Apple ships, with the same export names. | Trivial. Direct re-use. |
| PreviewsInjection's EntryPoint protocol family + XPC listeners (host↔agent message stream) | Our own protocol, specified in `prompts/ios-host-wire-protocol.md` (or its eventual successor). The shape is: `update(parameters: JITLinkPayload) async throws`, plus a `cancel()` async method. | Small. We define our own; we don't reuse PreviewsInjection. |
| PreviewsInjection's `RegisterSwiftExtensionEntrySection` | Our equivalent: after JIT-linking, walk the new image's `__TEXT,__swift5_entry` and friends and register with the Swift runtime via `swift_register_metadata`, `swift_register_protocols`, `swift_registerDynamicReplacements`. | Small-medium. The runtime registration is published Swift ABI. |
| Path selection (`__TEXT,__debug_dylib` populated vs JIT symbol present vs framework fallback) | We don't need three paths. We ship one (JIT). | n/a. |

Total agent-side runtime size estimate: low single-digit-kLOC. The host side is
where the design weight is — that's the LLVM ORC integration the W2 POC has
already substantially validated.

---

## 6. What's NOT closed: the address-list-per-edit-kind question

The spike scope's literal phrasing was "before/after diffs of the agent's
loaded image at JIT-link time: which vtable slots changed, which witness-table
entries changed, which symbol stubs were rewritten." Closing this at the
*specific address list* level requires runtime capture during a real
hot-reload — i.e., recording `__xojit_executor_write_mem(addr, len)`
sequences as the agent applies a patch.

**Status: still NOT closed.** Three capture-mechanism attempts to date,
all blocked at progressively deeper architectural layers. The mechanism
finding in §1-5 stands; only the per-edit address tuples remain unobserved.

### Attempts and outcomes

1. **dtrace `pid$target::*write_mem*:entry` against agent PID.** Apple's
   dtrace has a `dt_proc_create` gate that fails on signed agent binaries
   even with `csrutil disable` + `amfi_get_out_of_my_way=1`. The gate
   is separate from SIP/AMFI. Documented at
   [`xcode-driving-attempt.md`](../data/w3/xcode-driving-attempt.md).
2. **lldb attach to agent + breakpoint on `__xojit_executor_*`.** lldb
   reports `target create --arch arm64e <agent>` succeeds, but `process
   attach -p $PID` produces "No executable module" — dyld's loaded-image
   list does not propagate to lldb's view, so breakpoints stay pending.
   Compounded by previewsd's SIGKILL of the agent within seconds of
   lldb's attach pause (heartbeat timeout). Documented at
   [`canvas-driving-results.md`](../data/w3/canvas-driving-results.md).
3. **`DYLD_INSERT_LIBRARIES` interposer dylib via `launchctl setenv`.**
   Blocked at three independent barriers (full diagnosis at
   [`interposer-results.md`](../data/w3/interposer-results.md)):
   - `launchctl setenv` from an SSH session writes to the SSH bootstrap,
     not admin's GUI launchd session.
   - `open -a Xcode.app` (LaunchServices) strips DYLD_* env vars before
     reaching launchd.
   - previewsd reconstructs the agent's `DYLD_INSERT_LIBRARIES` from a
     hardcoded 5-entry list ([`agent-dyld-env.txt`](../data/w3/agent-dyld-env.txt)),
     not by inheriting/chaining the parent env.

The DYLD-env-injection path is conclusively closed. The interposer
dylib mechanism itself is correct — the table fires whenever the dylib
gets loaded — but no env-based delivery vector reaches the agent's
dyld.

### The genuinely-new architectural finding from attempt 3

The agent's hardcoded DYLD_INSERT_LIBRARIES chain has five entries:

| # | Path | Role |
|---|---|---|
| 1 | `/Applications/Xcode.app/.../usr/lib/libLogRedirect.dylib` | Xcode's stdout/stderr redirector |
| 2 | `/Applications/Xcode.app/.../libLiveExecutionResultsLogger.dylib` | Live-results telemetry recorder |
| 3 | `/Applications/Xcode.app/.../libPlaygrounds.dylib` | Playground/preview common hooks |
| 4 | `/System/Library/PrivateFrameworks/LiveExecutionResultsProbe.framework/...` | Probe-point insertion |
| 5 | `/System/Library/PrivateFrameworks/PreviewsInjection.framework/...` | Host↔agent JIT-link entrypoint |

Only entry #5 is load-bearing for the JIT-execution path. Entries
#1-4 support Xcode's playground/live-results UX. **Our public-layer
equivalent only needs to mirror #5** (host↔agent wire-protocol bridge);
the playground/live-results hooks are out-of-scope per
[`prompts/jit-executor-research.md`](../../prompts/jit-executor-research.md)
non-goals.

This is the same finding that closes the "what does our equivalent
need?" question in §5: one entry (PreviewsInjection-equivalent), not
five.

### Next-attempt fork: binary modification

Per [`interposer-results.md`](../data/w3/interposer-results.md) §
"Where to go next", the remaining viable capture path is Mach-O
modification — add an `LC_LOAD_DYLIB` for our interposer to the agent
binary directly, bypassing all env-injection. The handoff doc
[`handoff.md`](../data/w3/handoff.md) has the session-3 continuation
prompt and feasibility check for that approach.

### Original capture plan (for reference)

The following was the session-1 plan; preserved here in case a future
session finds a way past the dtrace gate.

**Pre-implementation runtime confirmation plan** (consumed by
`prompts/jit-executor-design.md` once written):

1. Boot `research/vm/` from the `post-xcode-sip-amfi` snapshot.
2. Drive Xcode via the VM's VNC + keyboard-scripting kit to create a
   stub SwiftUI macOS app project and open `ContentView.swift`.
3. Wait for the preview canvas to render. Note the
   spawned `XCPreviewAgent` PID via `ps`.
4. `sudo dtrace -n 'pid$target::*write_mem*:entry { ustack(); printf("addr=%p
   len=%d data=%x", arg1, arg2, arg2 > 0 ? *(uint64_t*)copyin(arg1,
   8) : 0); }' -p $AGENT_PID > /tmp/writes-before-edit.dtrace` (5 seconds, get
   baseline).
5. Edit one literal in `ContentView.swift`'s `body` (e.g. `Text("Hello")` →
   `Text("World")`). Save.
6. Capture writes for 5 seconds during the hot-reload.
7. Diff between baseline (idle agent) and hot-reload window. The non-empty diff
   = the patch-point address list, with call-stacks revealing which
   PreviewsInjection / XOJITExecutor code path triggered each.

Expected outcome (predicted from the static analysis above):

- A handful of `write_mem` calls at addresses inside the in-memory pseudodylib.
- Targeted addresses overwhelmingly in the pseudodylib's `__DATA,__const` /
  `__DATA_CONST,__const` (PWT slots).
- Possibly one or two writes in `__DATA_CONST,__got` if the edit introduced a
  new external symbol reference.
- Possibly a write into the agent's GOT (not the pseudodylib's) if the patch
  also redirects callers in the agent itself — though this is less likely
  given the agent's minimal own code size.

If the runtime confirmation surprises us (e.g., we see writes into the agent's
`__TEXT,__stubs` directly, or the patch model is not `write_mem`-based at all),
the design doc adjusts. That adjustment is implementation-time tuning, not
verdict-affecting.

---

## 7. Sanity check against the W2 POC's Phase 2.1 stretch goal

The W2 POC's Phase 2.1 stretch-goal log
(`.worktrees/jit-poc/research/jit-poc/data/run-witness-20260519T013611Z.log`)
established that JITLink resolves PWT pointer values at link time, and that
cross-JITDylib swaps *don't* retroactively rewrite already-linked PWT slots.
The hypothesis at that time was:

> (a) replace v1's witness-table data bytes in place (mprotect + memcpy at the
>     witness-table address);
> (b) factor the conformance into its own image referenced as an external by
>     v1, and replace that image (likely needs JITDylib replace /
>     undef-then-redefine).

W3's evidence resolves to **option (a)**, with one refinement: the
`mprotect`+`memcpy` is not done in our host process — it's done remotely in the
agent via `__xojit_executor_write_mem`, and the *decision* about which bytes
to write happens in the host's ORC instance during relocation resolution. Our
host's ORC drives the patch; the agent applies it.

Option (b) is *not* what Apple ships. The absence of any `replace`-style
symbol on either framework, plus the imports list showing the W^X-dance
primitives, is conclusive.

---

## Provenance

- `research/scripts/data/w3/XOJITExecutor-exports.txt` — the four
  `___xojit_executor_*` C-style exports. The complete remote-EPC vocabulary.
- `research/scripts/data/w3/XOJITExecutor-imports.txt` — the `_mprotect`,
  `_mach_vm_map`, `_memcpy`, `_memmove` imports.
- `research/scripts/data/w3/PreviewsInjection-imports.txt` — confirms
  PreviewsInjection imports `_memcpy` / `_memmove` but **not** `_mprotect` —
  i.e., it delegates W^X to XOJITExecutor.
- `research/scripts/data/w3/agent-lldb-jit-mode.txt` — lldb-resolved addresses
  for `__previewsInjectionPerformFirstJITLink`,
  `__previewsInjectionJITLinkEntrypoint`, `__xojit_executor_write_mem`,
  `__xojit_executor_run_program_on_main_thread`.
- `research/scripts/analysis/q6-jit-runtime-findings.md` — earlier evidence
  that XOJITExecutor is statically-linked LLVM ORC + JITLink.
- `prompts/jit-executor-findings.md` — Phase 2.1 stretch-goal results
  motivating options (a) and (b).
- LLVM upstream reference: `llvm/include/llvm/ExecutionEngine/Orc/SimpleRemoteEPC.h`
  + `llvm/tools/llvm-jitlink/llvm-jitlink-executor/llvm-jitlink-executor.cpp`
  — the public reference shape that XOJITExecutor mirrors.

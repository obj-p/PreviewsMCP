# JIT-link POC — Scope

**Workstream:** W2 deliverable #2 from `prompts/jit-executor-research.md`.

**Branch:** `jit-poc` (worktree at `.worktrees/jit-poc`).

**Why this exists:** The spike's load-bearing experiment. We now know
(from `research/scripts/analysis/q6-jit-runtime-findings.md`) that
Apple's runtime JIT-link engine IS LLVM ORC + JITLink, statically
linked behind a Swift/XPC façade in `XOJITExecutor.framework`. This
POC replicates the same architecture on **public** LLVM ORC and
`swiftc -emit-object`, minus the dyld pseudodylib trick. A positive
result means the architecture Apple ships is reachable from the
public layer.

## Phase 1 — what this POC tests

1. `swiftc -emit-object` of a trivial Swift source containing one
   function `greet()` that prints `hello from swift v1` produces an
   ARM64 macOS Mach-O object file.
2. LLVM ORC (`LLJIT` + `ObjectLinkingLayer`) inside a C++ host
   process can ingest that `.o` and resolve `greet`'s symbol address.
3. Calling the resolved function pointer from C++ prints
   `hello from swift v1` — i.e., relocations against Swift stdlib /
   libSystem are resolved against the host process's symbol table.
4. Recompiling the same Swift source with `print` changed to
   `hello from swift v2`, emitting a second `.o`, **without
   restarting the host process**.
5. Adding the second `.o` to the same `LLJIT` and re-resolving the
   symbol gives the v2 implementation when called. **This is the
   "function override via JIT-link" demonstration.**

## Success criteria

The POC's stdout (captured under `data/run-*.log`) contains, in
order:

    hello from swift v1
    hello from swift v2

with no aborts, missing-symbol errors, or relocation failures
between the two calls. **One run, one process, two object files,
two outputs.**

## What success means for the spike verdict

- **Strong yes for the trivial case.** LLVM ORC can ingest a Swift
  object file and resolve `print`'s stdlib chain to a running
  process — i.e., the *public-layer* glue (process-symbol resolver,
  ARM64 Mach-O relocation handling) works end-to-end on the trivial
  case Apple's runtime stack also exercises.
- **Does NOT yet validate Phase 2 surfaces** — see "Out of scope"
  below. Override semantics for the harder Swift emission patterns
  (TLVs, async, witness tables, generic metadata) are deferred. A
  Phase-1 success is necessary but not sufficient for the full
  spike verdict.
- **Does NOT touch Apple's private framework surface.** Zero
  imports of `XOJITExecutor`, `PreviewsInjection`, or
  `PreviewsPipeline`. We are NOT linking against Apple's preview
  stack — only against public LLVM ORC and the system's Swift
  runtime.

## Out of scope (Phase 1)

Phase 1 is intentionally minimal — a `hello world` plus a function-
override repeat — so that any failure surfaces the *most basic*
public-layer incompatibility, not a subtler Swift emission pattern.

Deferred to **Phase 2** (if Phase 1 works):

- **TLVs.** `@_thread_local` and module-level `let` initialization
  rely on `__thread_vars` / `__thread_data` / `__thread_bss`
  sections + `_tlv_bootstrap`. JITLink Mach-O support for TLVs has
  known gaps on arm64-macos. Phase 1 avoids TLVs by using only
  `print(_:)` at function scope — module-level state is not
  exercised.
- **Async functions.** Swift `async` lowers to a continuation-
  passing state machine with custom `swiftasynccc` calling
  convention and `__swift_async_extended_frame_info` metadata.
  Phase 1's `greet()` is sync.
- **Protocol witness tables.** Override semantics for
  protocol-method dispatch require patching witness-table entries
  (`docs/reverse-engineering.md` LT-2 patch-point set). Phase 1's
  `greet()` is a free function — no protocols.
- **Generic metadata registration.** Generic types register their
  metadata via `__swift_metadata_descriptors` / runtime registrars.
  Phase 1's `greet()` is concrete.
- **Class vtables.** Same reasoning as protocols.
- **Concurrent patching.** Phase 1's override happens between calls
  (single-threaded). No live-call swap.
- **Symbol-discovery sidecar.** Phase 1 assumes the override symbol
  name is known (it's `$s4poc5greetyyF`, the mangled `greet()`).
  Phase 2 would address symbol enumeration from build artifacts.
- **Cleanup of the v1 image.** Phase 1 leaves v1 in place; the v2
  add is *additive*. Whether that's the correct override mechanism
  vs `JITDylib::replace` / explicit unload is itself a Phase-2
  question (the answer informs concurrent-patch sequencing).
- **`#Preview` macro / SwiftUI rendering.** This POC tests the
  link-and-call mechanic only. SwiftUI integration belongs in
  later work.

## Out of scope (forever, for this POC)

- Apple's private wire protocols / XPC.
- Pseudodylib dyld extension (`__dyld_is_pseudodylib`). Our
  `.o`-derived images are normal-dyld-visible.
- Multi-Xcode-version coverage. POC tracks the currently selected
  toolchain (`xcode-select -p`).

## Failure modes that ARE the answer

If any of these fire, **stop and document** — the spike values a
clear "this is where the public layer breaks" verdict as much as
a working demo:

- ORC's `ObjectLinkingLayer` rejects the Swift `.o` at load time
  (Mach-O parse failure, unsupported section, unsupported
  relocation kind).
- Symbol resolution succeeds but calling the function aborts /
  segfaults — likely a Swift-runtime ABI mismatch the host process
  doesn't satisfy.
- `print` works but the v2 swap-in is invisible (`.o` is loaded
  but lookup still returns v1's address) — needs ORC API
  understanding more than guessing.
- `swiftc -emit-object` produces output that JITLink considers
  malformed — would be an upstream LLVM bug to file.

Each of these is documented in `data/run-*.log` with the exact
error and the next step that would unblock it.

## Build / run convention

- `build.sh` builds everything (Swift `.o`s + the C++ host).
- `./build/host` runs the demo and prints the two lines.
- Outputs captured to `data/run-<UTC-timestamp>.log` per run.

## Phase 2 preview (informational only)

After Phase 1 lands, the next experiments — in rough order of
spike-verdict load-bearing weight:

1. **TLV** — module-level `let x = computeExpensive()`; verify
   `_tlv_bootstrap` resolves and `x` reads correctly post-link.
2. **Protocol witness override** — declare a protocol with one
   method, two conforming types; override the conformance via JIT.
   This is the closest analogue to "hot-reload `body` of a SwiftUI
   `View`" and most directly informs W3's patch-point set.
3. **`async` function** — `func greetAsync() async`. Validate
   JITLink handles `swiftasynccc`.
4. **Concurrent override** — call `greet()` from a hot loop on a
   second thread while replacing it; verify no torn dispatch.

Phase 2 deliverable runs only if Phase 1 succeeds.

# JIT executor design

Multi-quarter implementation plan for PreviewsMCP's custom JIT executor on public
LLVM ORC + JITLink, authorized by the verdict in
[`prompts/jit-executor-findings.md`](jit-executor-findings.md) (Verdict #1: buildable;
supersedes thunk for the product target). This doc converts the spike's research
artifacts into a buildable specification — patch-point set, symbol-discovery
strategy, JITLink plugin architecture, concurrent-patch sequencing, build-pipeline
integration, and the host/agent split.

**Scope.** Design only. No implementation work in `Sources/` is authorized by this
doc; that's gated on a separate go/no-go that follows the Phase-1 host-side
prototype below.

**Inputs (load-bearing artifacts this design rests on).**
- [`prompts/jit-executor-findings.md`](jit-executor-findings.md) — the verdict.
- [`prompts/jit-executor-research.md`](jit-executor-research.md) — the scope this
  doc was called for ("Deliverables" #4).
- [`research/scripts/analysis/q6-jit-runtime-findings.md`](../research/scripts/analysis/q6-jit-runtime-findings.md)
  — Apple's runtime IS LLVM ORC + JITLink.
- [`research/scripts/analysis/w3-lifecycle-timeline.md`](../research/scripts/analysis/w3-lifecycle-timeline.md)
  — XCPreviewAgent envelope to mirror.
- [`research/scripts/analysis/w3-patch-point-set.md`](../research/scripts/analysis/w3-patch-point-set.md)
  — patch-mechanism finding (host-side ORC + agent-side
  `SimpleRemoteEPC` executor; option (a) in-place `mprotect`+`memcpy` patching).
- [`research/scripts/analysis/architecture-diagram-draft.md`](../research/scripts/analysis/architecture-diagram-draft.md)
  — public-layer analogue table for Apple's `PreviewsPipeline` sub-systems.
- POC: `.worktrees/jit-poc/research/jit-poc/` (branch `jit-poc`) — six Phase 2
  patterns (witness override, TLVs, `swift_once` globals, ObjC selref via custom
  plugin, async multi-await) JIT-link cleanly.

**Verified-against.** macOS 26.3.1, Xcode 26.2 (Build 17C49), Swift 6.2.3, LLVM 22.

---

## Goal / non-goals

**Goal.** A custom JIT-link executor for PreviewsMCP that delivers the four
product properties from
[`prompts/jit-executor-research.md`](jit-executor-research.md) → "Product target":
scales to large modules, build-artifact parity with `xcodebuild` / Bazel, edit-anywhere
hot-reload, long-term ABI stability on Mach-O + LLVM JITLink semantics. The
executor replaces the runtime-dylib delivery in
[`thunk-architecture.md`](thunk-architecture.md) for the product-target track,
while leaving the file-watcher / stable-module / runtime split otherwise intact.

**Non-goals.**
- No riding on Apple's stack at runtime: no link against
  `PreviewsPipeline.framework`, no consumption of `PreviewsJITLinkerParameters`,
  no calls to `__previewsInjection*`, no use of the `__dyld_is_pseudodylib` hook.
  Apple's stack is the reference design we emulate; we don't depend on it. This
  matches the spike scope's non-goals verbatim
  ([`prompts/jit-executor-research.md`](jit-executor-research.md) → "Non-goals").
- No iOS-host-app wire protocol design — that's adjacent territory in
  [`prompts/ios-host-wire-protocol.md`](#future-link) (to be written).
- No CodeGenerationIntelligence integration. Out of scope.
- No multi-Xcode-version coverage during implementation. We pin to one Swift
  toolchain (current GA at start of implementation) and rev forward at quarterly
  cadence.

**Architectural prerequisites.** Apple Silicon host (LLVM ORC's `MachOPlatform`
on `arm64-apple-macos*` is the load-bearing public-layer building block;
`x86_64` is not a target for the executor's host or agent). Public JIT
entitlement (`com.apple.security.cs.allow-jit`) on shipping agent binaries.
LLVM 22+ for the ORC ObjectLinkingLayer Plugin API used by our selref-uniquing
plugin (and the ObjC classlist plugin we still need to write).

---

## Architectural shape

The W3 patch-point-set analysis surfaced a load-bearing finding for this design:
**Apple's `XOJITExecutor.framework` is literally an LLVM `SimpleRemoteEPC`
executor**, with four C-style entrypoints (`___xojit_executor_write_mem`,
`_run_program_wrapper`, `_run_program_on_main_thread`, `_run_wrapper`) that
mirror LLVM's open-source `llvm-jitlink-executor` helper tool one-to-one. The
implication for our design: **we adopt the same host/agent split.**

```
                       (Bazel / xcodebuild build pipeline)
                                       │
                                       │  .o files, response file,
                                       │  linker arguments
                                       ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ HOST PROCESS — `previewsmcpd` (existing daemon)              │
   │  • SessionResolver (existing)                                │
   │  • FileWatcher (existing)                                    │
   │  • Compiler (existing, swiftc -emit-object)                  │
   │                                                              │
   │  ┌────────────────────────────────────────────────────────┐ │
   │  │  JIT-link host (new)                                   │ │
   │  │  • LLVM `LLJIT` instance per session                   │ │
   │  │  • ObjectLinkingLayer with our plugins:                │ │
   │  │      - ObjCSelrefPlugin (from POC)                     │ │
   │  │      - ObjCClassPlugin (new, ~150 LOC)                 │ │
   │  │      - SwiftEntrySectionPlugin (new)                   │ │
   │  │  • Symbol resolver:                                    │ │
   │  │      - Sidecar (custom linker pass — see §3)           │ │
   │  │      - Fall-back: agent's symbol table via remote-EPC  │ │
   │  │  • Per-edit patch-point planner (decides which slots   │ │
   │  │    in the agent's pseudodylib to overwrite)            │ │
   │  └──────────┬─────────────────────────────────────────────┘ │
   └─────────────│───────────────────────────────────────────────┘
                 │ SimpleRemoteEPC wire protocol
                 │   (Unix domain socket for local; XPC for in-app;
                 │    gRPC over TCP for device-side. See §6.)
                 │
                 │   WriteMemory(addr, bytes)
                 │   RunWrapper(fnAddr, args)
                 │   LookupSymbols(name) → addr
                 ▼
   ┌─────────────────────────────────────────────────────────────┐
   │ AGENT PROCESS — `PreviewAgent` (new)                         │
   │  • Mach-O main: minimal C executable (≈300 LOC)              │
   │  • LC_MAIN → executor_main:                                  │
   │      - parse argv: socket path / xpc endpoint                │
   │      - mach_vm_map JIT-eligible regions                      │
   │      - install GDB JIT debug interface (LLVM's plugin)       │
   │      - call SimpleRemoteEPCServer::Listen                    │
   │      - on first link: NSApplicationMain on a worker thread   │
   │  • DYLD_INSERT_LIBRARIES not needed (the agent IS the        │
   │    executor; we don't inject into an Apple binary)           │
   │  • Entitlements: com.apple.security.cs.allow-jit             │
   │                  com.apple.security.get-task-allow (dev)     │
   └─────────────────────────────────────────────────────────────┘
```

Three properties of this shape are load-bearing for everything below:

1. **The host owns the LLVM ORC instance.** All relocation resolution,
   symbol-graph construction, and patch-decision logic runs in
   `previewsmcpd`. The agent never imports `libLLVMOrcJIT` and has no
   knowledge of relocations or JITDylibs.
2. **The agent is a remote executor, not a runtime.** Its only verbs are
   "allocate memory," "write memory," "run program at address," "look up
   symbol in my own image." Apple's XOJITExecutor exposes the same four
   verbs. This is the public LLVM upstream pattern, not an Apple
   invention.
3. **The wire protocol is `SimpleRemoteEPC`, unmodified.** We do not invent
   our own protocol; we use LLVM's. Apple substituted XPC for socket;
   we may do the same for in-host-app deployments. The protocol shape is
   pluggable transport, fixed verbs.

This shape is *exactly* what the
[`research/scripts/analysis/architecture-diagram-draft.md`](../research/scripts/analysis/architecture-diagram-draft.md)
public-layer analogue table proposed for the two "large" rows ("LLVM ORC +
JITLink integration" and "patch-point runtime injection"), unified into
a single integrated stack. The remaining rows from that table are
mechanical reshaping.

### Mirroring `XCPreviewAgent`'s lifecycle envelope (selectively)

We adopt only the parts of XCPreviewAgent's lifecycle (per
[`w3-lifecycle-timeline.md`](../research/scripts/analysis/w3-lifecycle-timeline.md))
that map to our architecture:

| XCPreviewAgent feature | Our equivalent | Rationale |
|---|---|---|
| LC_MAIN → `___debug_blank_executor_main` (thin C entry) | `LC_MAIN → executor_main` (LLVM `SimpleRemoteEPCServer::main`) | Same role, public layer. |
| Dylib path (`__TEXT,__debug_dylib` populated at link time) | **Dropped.** | Legacy `@_dynamicReplacement` path. `thunk-architecture.md` covers this separately for the small-module holdover. |
| JIT path (PreviewsInjection injected, XPC-driven) | **Adopted as the primary path.** | This is our path. |
| Framework-agent fallback (NSApplicationMain → AppDelegate → idle) | **Adopted as the secondary path.** | Used when no preview is active: agent is alive, ready to receive a JIT-link request, but holds no pseudodylib yet. |
| `__PREVIEWS_AGENT_*` env vars | Distinct namespace (e.g. `PREVIEWSMCP_AGENT_*`); same semantics | Stderr redirect for stub-level debug; symbol-skip for sanity-check modes. |
| pseudodylib (`__dyld_is_pseudodylib`) | **Dropped.** Our in-memory images are normal-dyld-visible. | Apple uses pseudodylib to hide JIT'd code from `dlopen` scanners; not a feature we need. |
| `cancelUpdate` async method | Adopted as part of the host↔agent wire protocol. | Drain-before-patch handshake. |

---

## 2. Patch-point set

What we patch on every edit, ordered by likely frequency. Full mechanism analysis
is in
[`research/scripts/analysis/w3-patch-point-set.md`](../research/scripts/analysis/w3-patch-point-set.md);
this section is the *specification* for the host-side patch-point planner.

| Surface | Mach-O section | When written | Patch shape |
|---|---|---|---|
| Protocol witness table entry | `__DATA_CONST,__const` (PWT slot) | Every edit that changes a `body` (SwiftUI's `View`/`Scene` body is witnessed). | Single pointer-width `write_mem` at the slot's runtime address. |
| Class vtable slot | `__DATA_CONST,__const` (class metadata vector) | Edit that changes an overridable method on a class. | Single pointer-width `write_mem`. |
| GOT entry | `__DATA_CONST,__got` | Edit that introduces / changes an external symbol reference. | Single pointer-width `write_mem` at GOT slot. |
| `__TEXT,__stubs` entry | `__TEXT,__stubs` | Less common in SwiftUI; mostly relevant if the edit changes a lazy-resolved stub target. | Stub bytes overwritten (typically the `B` target). |
| Async function pointer | `__TEXT,__swift_as_entry` + `__TEXT,__swift_as_ret` | Edit that changes an `async` function body. | Pointer-width `write_mem` into the entry slot. POC Phase 2.3 exercised the relocation behavior. |
| TLV initializer | `__DATA,__thread_vars` + `__DATA,__thread_data` | Edit that changes module-level `@_thread_local` state. | `write_mem` of `tlv_init` slot. POC Phase 2.2 exercised this. |
| `swift_once` global-init function pointer | `__DATA,__data` (addressor) + `__DATA,__bss` (token) | Edit that changes module-level `let`/`var` initialization. | Patch `_…_WZ` pointer; reset `_…_Wz` token to re-fire. POC Phase 2.2 exercised this. |
| ObjC selref slot | `__DATA,__objc_selrefs` | Edit that introduces a previously-unused selector. | `write_mem` of canonical SEL address. **Plugin required** — see §4. POC Phase 2.2.5 closed this gap. |
| ObjC class slot | `__DATA,__objc_classlist` | Rare in pure SwiftUI; possible when a preview emits an ObjC class. | `write_mem` of class struct address after host-side `objc_registerClassPair`. **Plugin required** — see §4. Apple's PreviewsInjection does not import `objc_register*`, suggesting they avoid this case or handle host-side. |

### Per-edit address-list capture (the runtime confirmation step)

The address list ABOVE is the universe of *kinds*; the *specific addresses*
written for a given edit are produced by ORC's relocation resolver at
link-finalize time. We have *not* yet observed Apple's per-edit address list
under real load. Three capture-mechanism attempts have been blocked at
progressively deeper architectural layers:

1. dtrace `pid$target` provider — gated on signed binaries independent of
   SIP/AMFI.
2. lldb attach + breakpoint — "No executable module" pathology when
   attaching to the running agent; previewsd's heartbeat SIGKILLs the
   agent during attach pause.
3. `DYLD_INSERT_LIBRARIES` interposer dylib via `launchctl setenv` — three
   stacked barriers: (a) launchctl-setenv from SSH doesn't reach the GUI
   launchd session, (b) `open -a Xcode.app` strips DYLD_* via
   LaunchServices, (c) previewsd reconstructs the agent's
   `DYLD_INSERT_LIBRARIES` from a hardcoded 5-entry list rather than
   inheriting.

See
[`w3-patch-point-set.md`](../research/scripts/analysis/w3-patch-point-set.md) §6
and
[`research/scripts/data/w3/interposer-results.md`](../research/scripts/data/w3/interposer-results.md)
for the full diagnosis. The next-attempt fork is Mach-O binary
modification of `XCPreviewAgent` (append `LC_LOAD_DYLIB` for an
interposer) — outlined in
[`research/scripts/data/w3/handoff.md`](../research/scripts/data/w3/handoff.md).

The capture is **not blocking for Phase 1** (host-side prototype) and **not
blocking for Phase 2** (agent-side executor). It's blocking for the
production-hardening phase only — by then we need to know empirically that our
patch-point planner agrees with Apple's choices, or surface the divergence.

### Architectural finding from attempt 3 (informs §5)

The agent's hardcoded `DYLD_INSERT_LIBRARIES` chain has five entries
([`research/scripts/data/w3/agent-dyld-env.txt`](../research/scripts/data/w3/agent-dyld-env.txt)).
Only one — `PreviewsInjection.framework` — is load-bearing for the JIT
path. The other four (libLogRedirect, libPlaygrounds,
libLiveExecutionResultsLogger, LiveExecutionResultsProbe) support
Xcode's playground / live-results UX, which our public-layer equivalent
does not need to mirror. The §5 "Public-layer analogue checklist" row
"PreviewsInjection's EntryPoint protocol family" is the only injection
point we replicate.

---

## 3. Symbol-discovery strategy

The host-side ORC needs to know, for every symbol referenced by a JIT-linked
`.o` file, where to find it. Three sources of truth:

1. **The stable module's own symbol table.** Already built, on disk, easy.
2. **The Swift / system runtime symbol table.** Resolvable via `dlsym` against
   the agent process's loaded images (using `SimpleRemoteEPC`'s
   `LookupSymbols` verb to query the agent over the wire).
3. **Cross-module symbols (Foundation, AppKit, third-party SDKs).** Same as
   (2) — the agent has them loaded; we ask the agent.

The interesting symbols are the ones we want to *patch*: PWT entries, vtable
slots, GOT entries that exist in the running agent's pseudodylib. For those,
we need the *address* of the slot in the agent's memory, not just the symbol's
identity.

### Option A — sidecar from a custom linker pass

When the stable module's `.o` files are linked into the agent's initial image,
we emit a sidecar file: a JSON / binary index keyed by mangled symbol name,
mapping to `(section, offset, kind)` for every patch-relevant symbol. The
host's patch-planner consumes this sidecar at session start.

**Pros.** Fast — patch-point address resolution is O(1) dictionary lookup. Zero
per-edit overhead. Stable across edits (the stable module's symbol layout
doesn't change between edits — only the thunk does). Build-system friendly:
the sidecar is produced once at the same point as the `.o` files.

**Cons.** Requires a custom step in the build pipeline (a SwiftPM /
Bazel post-link pass). Adds a build-system integration surface to maintain.

### Option B — lazy intercept-on-call resolver

Skip the sidecar. At first call to a patch target, the host's ORC's lookup
machinery resolves the symbol on demand, queries the agent for the address,
and caches it. Cache misses cost one wire round-trip; subsequent calls are
in-process lookups.

**Pros.** No build-pipeline integration. Works against any pre-built `.o` set
(SwiftPM, Bazel, xcodebuild) without modification. Matches how LLVM ORC's
`LLJIT` natively works (the lazy-resolution pattern is its default).

**Cons.** First-call latency per symbol (wire round-trip to the agent). Cache
warm-up cost on every session start. The cache state has to be invalidated
correctly when the pseudodylib changes shape (rare but possible — e.g. when a
new field is added to a class).

### Recommendation: sidecar (Option A), with lazy fallback

Hybrid model:
- The stable module's build emits the sidecar. Host loads it at session start
  for O(1) patch-target lookup.
- For symbols not in the sidecar (e.g. a transitively-imported third-party
  framework that wasn't sidecar-emitted), fall back to lazy lookup against
  the agent's symbol table.

This avoids both extremes. Sidecar emission is a ~200-LOC SwiftPM plugin and a
~200-LOC Bazel rule-modification — both within reasonable engineering scope.

**Sidecar format (proposal).** Binary, mmap-able, two sections:

```
header {
  magic:        u32     # 'PMSC' (PreviewsMCP Sidecar)
  version:      u32     # = 1
  module_name:  cstr32  # bounded module name
  symbol_count: u64
}
symbol_entry[symbol_count] {
  hash:         u64     # FNV-1a of mangled name (fast lookup)
  name_offset:  u32     # offset into name table
  section_id:  u16     # __DATA_CONST,__const = 1; __DATA_CONST,__got = 2; etc.
  flags:        u16     # PATCH_KIND_PWT = 0x01, _VTABLE = 0x02, _GOT = 0x04, _STUB = 0x08
  rel_offset:   u64     # offset from segment start; resolved to runtime addr at session start
}
name_table {  # null-terminated mangled names
  cstr...
}
```

This is the design-time format. We can revise once we have a Phase-1 prototype
running and measure lookup costs.

---

## 4. JITLink plugin architecture

LLVM's `ObjectLinkingLayer::Plugin` API is the extension surface for handling
Mach-O sections that JITLink doesn't process out-of-the-box. The POC closed
one gap (`__objc_selrefs`) with a ~150-LOC plugin
([`.worktrees/jit-poc/research/jit-poc/src/ObjCSelrefPlugin.{hpp,cpp}`](../.worktrees/jit-poc/research/jit-poc/src/ObjCSelrefPlugin.hpp)).
One more is known-needed (`__objc_classlist`), and one is W3-specified
(`__swift_extension_entry` / `__swift5_entry` runtime registration). Additional
plugins may surface as Swift versions advance.

| Plugin | Status | Purpose | Size |
|---|---|---|---|
| `ObjCSelrefPlugin` | ✅ written (POC) | Walks `__DATA,__objc_selrefs`, calls `sel_registerName` for each cstring, rewrites edges to canonical SEL addresses. | ~150 LOC. Reusable as-is. |
| `ObjCClassPlugin` | TODO | Walks `__DATA,__objc_classlist`, calls `_objc_realizeClassFromSwift` or `objc_registerClassPair` for each class struct, rewrites class slot. | ~150 LOC (selref-shaped). |
| `SwiftEntrySectionPlugin` | TODO | After JIT-link, walks the new image's `__TEXT,__swift5_entry` / `__TEXT,__swift_extension_entry` and registers contents with the Swift runtime (calls equivalent of `swift_register_dynamic_replacements`, `swift_registerProtocolConformanceRecords`, `swift_registerTypeMetadataRecords`). | ~200 LOC. The Swift runtime registration entry points are public via `<swift/Runtime/Metadata.h>`. |
| `PatchPointPublishPlugin` | TODO | After JIT-link, publishes the per-edit patch-target addresses (resolved via the sidecar from §3) to the host's patch-planner. Coordinates the actual `write_mem` calls. | ~250 LOC. The "make patches happen" plugin. |

### Plugin lifecycle (from POC's empirical findings)

Per `reference_jit_poc_artifacts` (auto-memory), the LLVM plugin API has the
following non-obvious requirements, learned via the selref plugin:

- Plugin base class is `LinkGraphLinkingLayer::Plugin`, **not** the more
  obvious `ObjectLinkingLayer::Plugin` (the latter inherits from the former).
- Pure-virtual methods that MUST be implemented (even as no-ops):
  `notifyFailed`, `notifyRemovingResources`, `notifyTransferringResources`.
- The right pass phase for section-walking + edge retargeting is
  `PostPrunePasses` (NOT `PreFixupPasses`).
- LinkGraph section names use canonical Mach-O `__SEG,__sect` form
  (`__DATA,__objc_selrefs`), not bare names.
- The plugin runs against **every** link, including the ORC runtime archive
  slices and `<MachOHeaderMU>` materialization units — graceful early-out on
  missing section is essential.

These constraints carry over to every additional plugin we write.

---

## 5. Concurrent-patch sequencing

The patch mechanism (option (a) in-place `mprotect`+`memcpy` via
`write_mem`) is correct under three conditions:

1. **In-flight calls must not observe a torn pointer.** Each patched slot is
   pointer-width aligned; AArch64 guarantees pointer-width atomic load/store
   when both are aligned. So an in-flight call either sees the old function
   pointer or the new one, never a half-stored composite.
2. **The new function pointer's image must be *loaded* before the patch is
   applied.** Otherwise an in-flight call could jump to memory that's been
   `write_mem`'d but not made executable. The JITLink finalize pass orders
   "make executable" before "publish symbol address" before "patch slots."
3. **Patch must not race against agent's own initialization or teardown of
   the same image.** Solved by main-thread marshaling: the agent runs
   `RunProgram` (which is what evaluates the JIT'd code) on the main thread,
   and we marshal `write_mem` for *patches against an executing image* onto
   the same main thread.

### The cancelUpdate handshake

Apple's `PreviewsInjection.EntryPoint` protocol exposes `cancelUpdate() async ->
()`. We mirror this:

```
HOST                                                  AGENT
  │                                                     │
  │  ─── BeginUpdate(updateId) ───────────────────────▶ │
  │                                                     │  acks; sets currentUpdate = updateId
  │                                                     │
  │  ─── WriteMemory(addr_1, bytes_1) ────────────────▶ │
  │  ─── WriteMemory(addr_2, bytes_2) ────────────────▶ │
  │  ─── ... ────────────────────────────────────────▶  │
  │                                                     │
  │  ─── EndUpdate(updateId) ─────────────────────────▶ │  marshal RunProgram on main thread
  │                                                     │
  │  ◀───────────── UpdateComplete(updateId) ───────────│
```

If the host sends `CancelUpdate(updateId)` mid-stream:
- The agent stops accepting `WriteMemory` for that updateId.
- The agent reverts in-progress writes from a small per-update redo log
  (~1 KB scratch buffer).
- The agent reports back via `UpdateCancelled(updateId)`.

The redo log is the only state the agent maintains for concurrency
correctness; everything else (which slots to write, in which order) is the
host's responsibility.

### Why this is sufficient (and what we deliberately don't do)

We deliberately do **not** suspend the agent's threads during patching. The
seam between "patch landed" and "next call observes the patch" is the atomic
pointer-write at the slot level; thread suspension would be belt-and-suspenders
and would introduce its own correctness problems (e.g., a thread suspended
inside a witness function won't release any locks it holds, so suspension
order matters for liveness).

This matches what the W3 evidence suggests Apple does — XOJITExecutor exposes
no thread-suspend / thread-list primitives, and `RunProgram_on_main_thread`'s
specific main-thread marshaling is the agent's only concurrency hook.

---

## 6. Wire protocol overview

LLVM `SimpleRemoteEPC` over a pluggable transport. The transport choice
depends on deployment shape:

| Deployment | Transport | Reason |
|---|---|---|
| Local agent process (current PreviewsMCP daemon shape) | Unix domain socket | Trivial to set up. LLVM's `SimpleRemoteEPC` defaults to socket. |
| In-host-app agent (macOS host-app target — see [`thunk-architecture.md`](thunk-architecture.md) for iOS analogue) | XPC | Matches Apple's choice; survives host-app lifecycle. |
| iOS device-side agent | gRPC over TCP (or QUIC) | Off-device → on-device, via the wire-protocol design in [`prompts/ios-host-wire-protocol.md`](#future-link) (TBD). |

The verbs are LLVM's stock SimpleRemoteEPC vocabulary; we extend with two
PreviewsMCP-specific verbs for the update lifecycle:

| Verb | Direction | Purpose |
|---|---|---|
| `WriteMemory(addr, bytes)` | host → agent | The patch primitive. |
| `ReadMemory(addr, len) -> bytes` | host → agent | For diagnostics / golden-image diffing in dev mode. |
| `LookupSymbols(names) -> addrs` | host → agent | Initial address resolution for symbols not in the sidecar. |
| `RunWrapper(fnAddr, argsBuf) -> resultBuf` | host → agent | Run a JIT'd function with marshaled args. |
| `RunOnMainThread(fnAddr, argsBuf)` | host → agent | Same, marshaled onto agent's main thread. |
| `BeginUpdate(updateId)` *(extension)* | host → agent | Start a per-update patch transaction. |
| `EndUpdate(updateId)` *(extension)* | host → agent | Commit + run. |
| `CancelUpdate(updateId)` *(extension)* | host → agent | Abort + revert. |
| `UpdateComplete / UpdateCancelled / Diagnostic` *(extension)* | agent → host | Async notifications. |
| `Dispose()` | host → agent | Tear down. |

We don't reinvent the JIT debug interface — LLVM's `DebuggerSupportPlugin` +
the standard `__jit_debug_register_code` + `__jit_debug_descriptor` symbol
contract is what the agent advertises. lldb / gdb see the JIT'd code via
the standard mechanism.

---

## 7. Build-pipeline integration

PreviewsMCP's existing pipeline (`Compiler.swift:128-141`, `SPMBuildSystem.swift:548-582`,
plus the planned re-design under [`prompts/thunk-architecture.md`](thunk-architecture.md))
already invokes `swiftc -emit-object` for the thunk dylib. For the JIT executor
we change three things:

1. **Stable module emission**: continue building the stable module to `.o`
   files (already happens). Add a sidecar emission post-pass (§3).
2. **Thunk emission**: instead of linking the thunk to a dylib and dlopening,
   keep the `.o` files and hand them to the host-side JIT-link host. The
   `LinkerArgumentIngestor`-equivalent is a ~300-LOC Swift utility that
   transforms the build's linker argument list into the LLVM ORC
   `MaterializationUnit` shape.
3. **Skip codesign**: no `codesign_allocate` step. The agent's JIT-eligible
   pages don't need to be code-signed (they live in `MAP_JIT` memory, which
   the JIT entitlement permits without per-page signing).

### swiftc invocation reuse from POC

The POC's `build.sh` (`.worktrees/jit-poc/research/jit-poc/build.sh`) is the
template. Production differences:

- Drop the `-target arm64-apple-macos26.0` workaround documented in the POC
  (use `-sdk $(xcrun --sdk macosx --show-sdk-path)` instead).
- Drop the brewed LLVM 22 dependency from the production build — production
  links against a pinned LLVM 22+ checkout (vendored or via a SwiftPM target).
- The ORC runtime archive (`liborc_rt_osx.a`) ships as a vendored static
  archive in `Sources/PreviewsJITRuntime/Resources/`, thinned to arm64 only.

### SwiftPM and Bazel integration

The build-system integration is symmetric to the thunk path: the existing
`SPMBuildSystem.swift` and Bazel rule paths need to emit the sidecar and
pass `.o` paths to the JIT-link host instead of producing a thunk dylib. The
existing `PreviewsBuild` extraction proposed in
[`prompts/modularization.md`](modularization.md) gives us a clean seam for
this.

---

## 8. Implementation phasing

Four phases. Each phase ends with a buildable + testable artifact.

### Phase 1 — Host-side LLVM ORC harness (in-process)

**Goal.** Validate the host-side JIT-link decision and patch-point planner
work correctly in-process, without an agent. Run JIT'd Swift code in the
daemon's own process; patch its own memory.

**Scope.**
- Sources/PreviewsJITLink (new Swift target wrapping a C++ harness).
- C++ harness wraps `LLJIT` + `ObjectLinkingLayer` + the three plugins from §4.
- Reads `.o` files produced by the existing `Compiler.swift`.
- Symbol resolution: simple in-process (resolves against `dlsym` of the
  daemon's own loaded images).
- Patch-point planner: in-process — addresses are local.
- No wire protocol.
- No agent process.

**Acceptance.** A `PreviewsJITLinkTests` test-suite that mirrors the POC's six
Phase 2 scenarios (witness, TLV, swift_once, ObjC selref, ObjC class, async),
running in-process inside the test runner. Each test ships as a Swift source
file + assertion that the JIT-linked function returns the expected value.

**Sizing.** ~6 weeks. Most of the cost is integrating LLVM 22 into PreviewsMCP's
build (vendoring vs SwiftPM dependency vs CMake bridge).

### Phase 2 — Agent process + SimpleRemoteEPC

**Goal.** Move JIT-link execution out-of-process. The daemon stays the JIT-link
host (Phase 1's harness); a new `PreviewAgent` binary becomes the executor.

**Scope.**
- New `Sources/PreviewAgent` target — produces the agent Mach-O.
- Agent links LLVM's `SimpleRemoteEPCServer` (≈250 LOC of C++ glue).
- Agent has minimal entitlements (`com.apple.security.cs.allow-jit`,
  `com.apple.security.get-task-allow` for dev builds).
- Daemon switches from in-process LLJIT to `SimpleRemoteEPC`-driven LLJIT
  pointing at the agent process over a Unix domain socket.
- Agent process lifecycle: spawned by the daemon at session start, killed
  at session end. Inherits the daemon's working directory and a per-session
  socket path.

**Acceptance.** The same six tests from Phase 1 pass, but with the JIT'd code
running in the agent and the host driving over the wire. Measured wire-protocol
latency for a single `WriteMemory` round-trip < 1ms locally (sanity threshold).

**Sizing.** ~4 weeks. The agent itself is small; the cost is the
`SimpleRemoteEPC` transport plumbing and process-lifecycle management.

### Phase 3 — SwiftUI integration + hot-reload

**Goal.** Wire the JIT executor into PreviewsMCP's session lifecycle. Replace
the thunk path with the JIT-link path for the "structural edit" tier of
`PreviewBuildDiff`.

**Scope.**
- The existing FileWatcher + Compiler + SessionResolver pipeline routes
  structural edits to JIT-link instead of thunk-rebuild.
- The thunk path is preserved for the literal-only tier
  (`LiteralRegionClassifier` already classifies these — see
  [`thunk-architecture.md`](thunk-architecture.md) — and they don't need JIT
  link, just `DesignTimeStore` updates).
- `PatchPointPublishPlugin` (§4) is wired so that each structural edit
  produces a `WriteMemory` sequence.
- The agent runs the SwiftUI preview body on its main thread; the host
  drives updates without restarting.

**Acceptance.** A new `examples/` project demonstrates: change a literal in
`Text("…")` → hot-reload via `DesignTimeStore` (existing path, ~10ms).
Change a non-literal in the same body → JIT-link reload (new path, target
<200ms for a single-file edit on a 100-file module). Examples scale up
through 100-, 500-, 1000-file modules.

**Sizing.** ~8 weeks. The integration is mostly mechanical (the existing
session/file-watcher/compiler glue is already in place); the cost is in the
plumbing details and validating the latency targets.

### Phase 4 — Production hardening + large-module scaling

**Goal.** Cross the line from "works for small examples" to "ships."

**Scope.**
- Large-module scaling spike: synthetic 1000-file Swift module + a thunk.
  Measure JIT-link wall time, peak memory, per-edit re-link time. (The
  pre-implementation TODO from
  [`prompts/jit-executor-findings.md`](jit-executor-findings.md) →
  "What's not yet verified" / "Large-module scaling".)
- Per-edit patch-point address-list confirmation: run
  [`research/scripts/data/w3/capture-write-mem.d`](../research/scripts/data/w3/capture-write-mem.d)
  against Xcode's XCPreviewAgent on a real preview edit; verify our
  planner's patch-target set agrees. Surface divergence as a bug.
- ObjC classlist plugin (§4) — close the W2 unclosed gap.
- Code-sign the agent for distribution (Mac App Store guidelines, JIT
  entitlement profile). Validate the entitlement chain on shipped builds.
- Crash recovery: agent crash → host re-spawns and re-establishes session
  state.
- Multi-session: N concurrent agents (for agentic workflows running many
  preview sessions in parallel).
- Telemetry: signpost events for every wire round-trip and patch, for
  perf-tracking dashboards.

**Acceptance.** Internal beta against 5-10 real production codebases, with
documented latency / memory / crash-rate baselines.

**Sizing.** ~10 weeks. The long tail of production-grade work.

---

## 9. Open implementation-time questions

Resolved at implementation time, not at design time. Listed so future-me /
future-other knows where to push when each comes up:

1. **LLVM ORC version pinning.** What LLVM major release do we pin against?
   LLVM 22 was the POC version; pinning to a moving target is fragile. Likely
   we pin against the LLVM release Swift 6.2 itself uses, and bump as Swift
   bumps.
2. **Agent binary distribution.** Ship the agent inside the PreviewsMCP
   package (so updates are atomic), or as a separate downloadable artifact
   per platform (so the package stays small)? Probably the former for v1,
   refactor to separate distribution if size becomes a problem.
3. **Sidecar generation in Bazel.** SwiftPM's plugin API gives us a clean
   place to emit the sidecar; Bazel's rule-swift overlay is less clean.
   Open question whether we ship our own `swift_jit_module` macro or extend
   `swift_library` via aspects.
4. **Cross-module patch points.** A preview edit in module A that affects a
   symbol re-exported from module B — does the patch happen in A's sidecar
   slot, B's, or both? Resolve once we have a multi-module test fixture.
5. **Swift runtime registration timing.** The `SwiftEntrySectionPlugin` (§4)
   registers metadata records with the Swift runtime. When does Swift
   *unregister* them? If we re-JIT-link the same module 100 times in a
   session, do we accumulate 100 stale records? Worth measuring.
6. **Bazel hermetic build interplay.** Bazel's hermeticity guarantees may
   interact awkwardly with our agent's pseudodylib (since the JIT-linked
   image isn't a Bazel output and won't be in the action cache). Likely
   fine because we don't *re-link* via Bazel during a session, but flag.
7. **`com.apple.security.cs.allow-jit` certificate provisioning.** Developer
   ID + Apple Developer Program certificate setup for shipping a JIT-enabled
   binary. Bureaucratic, not technical, but on the critical path for
   distribution.

---

## 10. What this design *doesn't* cover

- **Wire-protocol details for iOS** — separate doc
  ([`prompts/ios-host-wire-protocol.md`](#future-link), TBD). This doc's wire
  protocol is the in-process / local-socket / XPC shape; iOS adds gRPC
  transport, device discovery, and bridging.
- **Build-system specifics for non-SPM/non-Bazel** — Tuist, manual
  `xcodebuild`, plain CMake-via-swift-bridge. Each gets a small adapter
  layer in Phase 3.
- **Multi-Xcode-version compatibility.** Pinned to one Swift toolchain per
  release. Bumping is mechanical but not zero-cost.
- **`@_dynamicReplacement` interaction.** The thunk path coexists with the
  JIT-link path for literal-only edits. They don't interact; the
  classifier ([`thunk-architecture.md`](thunk-architecture.md)) routes
  cleanly.

---

## Provenance

Every architectural claim in this doc is grounded in a specific artifact:

- W3 lifecycle envelope and patch mechanism: `research/scripts/analysis/w3-{lifecycle-timeline,patch-point-set}.md`.
- Q6 LLVM ORC confirmation: `research/scripts/analysis/q6-jit-runtime-findings.md`.
- Public-layer analogue table: `research/scripts/analysis/architecture-diagram-draft.md`.
- POC building blocks: `.worktrees/jit-poc/research/jit-poc/{src,swift,data}/`,
  commits `5cb8277..95db2ed` on branch `jit-poc`.
- LLVM upstream:
  `llvm/include/llvm/ExecutionEngine/Orc/{LLJIT,ObjectLinkingLayer,SimpleRemoteEPC}.h`,
  `llvm/tools/llvm-jitlink/llvm-jitlink-executor/llvm-jitlink-executor.cpp`,
  `llvm/include/llvm/ExecutionEngine/Orc/Debugging/DebuggerSupportPlugin.h`.

Authoritative for the JIT-executor design until Phase 1 lands and produces a
real prototype, at which point this doc gets revised against measured behavior.

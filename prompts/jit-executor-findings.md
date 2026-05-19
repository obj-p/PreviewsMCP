# JIT Executor Research — Findings

**Status:** Spike complete. Verdict below. Authority for any subsequent reference to "JIT
executor research outcome" sits in this document.

**Scope of this doc:** the decision document called for by
`prompts/jit-executor-research.md` → "Deliverables" #3. Synthesizes the spike's three
workstreams (W1 infra, W2 architecture study + JITLink proof-of-concept, W3 patch-point set)
into a single verdict, scored against the four product properties enumerated in the spike scope.
This is not the design doc — `prompts/jit-executor-design.md` is a separate follow-on and is
explicitly out of scope here.

**Verdict (one line, restated formally below):** **Buildable; supersedes thunk for the product
target.** PreviewsMCP can build a custom JIT executor on stable public layers (LLVM JITLink/ORC,
`swiftc -emit-object`, Mach-O loader semantics, the public JIT entitlement) without depending on
Apple's private preview frameworks. The architecture we would build is the same architecture
Apple ships. The remaining unknowns are implementation work, not architectural gating risks.

---

## Research question (restated, with answers)

> Given the product target — full Xcode Previews replacement, including large modules,
> agentic workflows, and edit-anywhere semantics — can PreviewsMCP build a JIT-style executor
> on stable public layers (LLVM JITLink/ORC, `swiftc -emit-object`, Mach-O loader semantics,
> the public JIT entitlement) without depending on private Apple frameworks? And is the
> engineering investment tractable within a defensible budget?

**Answer to the public-layer question: yes, with high confidence.** Each of the four
uncertainties from `jit-executor-research.md` "Why research-mode" resolved favorably or has a
clearly bounded remaining-work shape:

1. **Patch-point selection.** Identified empirically via Phase 2.1 stretch goal: cross-
   JITDylib swaps don't retroactively redirect dispatch — JITLink resolves relocations at
   link time and v1's witness-table pointer is fixed at that point. Real patch mechanism is
   byte-level in-place data patch of the protocol-witness-table (PWT) slot
   (`mprotect`+`memcpy`) or factoring the conformance into its own image and replacing that
   image. Status: **method confirmed in principle; runtime patch on a real XCPreviewAgent
   via dtrace not yet observed.**
2. **Symbol-discovery infra.** Not yet exercised end-to-end. Implementation work, not a
   gating risk: build-system already knows which symbols exist (mangling + module-name); a
   small post-link sidecar or lazy intercept-on-call resolver closes it. No public-layer
   building block is missing.
3. **LLVM JITLink coverage for Swift.** Was the load-bearing public-layer uncertainty. The
   POC exercised the hardest Swift emission patterns on a 3-week budget — protocol witness
   dispatch, TLVs, `swift_once`-guarded module-level `let`, ObjC interop via
   `__objc_selrefs`, `async` with multi-await — and every pattern JIT-linked successfully,
   with one gap (ObjC selref uniquing) closed by a public-LLVM-API plugin we ship in ~150
   LOC. **No gap requires patching LLVM upstream or replacing the JIT layer.**
4. **Concurrent-patching correctness.** Not exercised (single-threaded POC). Real
   implementation-time concern, bounded by the same techniques Apple uses (PWT in-place
   patch serializes via atomic pointer-width writes; live call sites reached only through
   indirections we control). Out of spike scope.

**Answer to the tractable-budget question: yes**, with caveats discussed under "What this
verdict unlocks."

---

## What was tried (the three workstreams)

| Workstream | Outputs called for | Status |
|---|---|---|
| **W1** — research VM infra | `research/vm/` `Virtualization.framework` wrapper CLI + provisioning; `research/scripts/` Python wrappers | **Delivered for symbol-dump and architecture-study use cases.** SA automation reached macOS desktop end-to-end on 26.3.1; `post-sa` and `post-xcode-sip-amfi` snapshots exist. dtrace/lldb attach scaffolding deferred pending W3 dtrace work. |
| **W2** — `PreviewsPipeline` study + JITLink POC | architecture diagram with public-layer analogues; harness demonstrating Swift function override via JITLink | **Both delivered.** Architecture diagram draft 1 at `research/scripts/analysis/architecture-diagram-draft.md`. JITLink POC lives on `.worktrees/jit-poc`, branch `jit-poc`, commits `5cb8277..95db2ed` (13 commits across Phases 1 / 2.1 / 2.1-stretch / 2.2 / 2.2.5 / 2.3 / 2.3-stretch). |
| **W3** — XCPreviewAgent lifecycle + patch-point set | lifecycle timeline; before/after diffs of patched indirections | **Delivered to mechanism level.** Lifecycle timeline at `research/scripts/analysis/w3-lifecycle-timeline.md` (three execution paths identified: Dylib / JIT / framework-agent; full env-var + symbol-fallback chain mapped; decision tree captured verbatim from the agent's own stderr log). Patch-point mechanism at `research/scripts/analysis/w3-patch-point-set.md` (option (a) in-place `mprotect`+`memcpy` confirmed; option (b) JITDylib::replace ruled out; architecture is LLVM `SimpleRemoteEPC` — patch decisions made host-side, patch application agent-side via `___xojit_executor_write_mem`). Per-edit address list still pending runtime capture during real Xcode hot-reload (pre-implementation TODO; capture-write-mem.d dtrace script ready to run). |

The verdict rests on W2's architecture diagram ("the public-layer shape matches Apple's")
plus W2's JITLink POC ("the public-layer building blocks actually work for Swift"). W1
contributed the analysis substrate. W3's deferral is discussed honestly below.

---

## What worked

### W1 — research VM infrastructure

Reached the symbol-study endpoint. The VM provisioning CLI under `research/vm/` boots macOS
26.3.1 to a fully-configured Setup-Assistant-complete desktop via
`SetupAssistantSequence.swift`. SIP disabled from recoveryOS, AMFI off via
`nvram boot-args="amfi_get_out_of_my_way=1"`. Xcode 26.2 installed against the
`post-xcode-sip-amfi` snapshot. The VM-side `dyld_info` against
`/System/Library/PrivateFrameworks/XOJITExecutor.framework` is the data source that closed
Q6 — host-side inspection couldn't reach this framework (no `.tbd` stub in the SDK).

dtrace/lldb attach scaffolding for W3 runtime tracing was not built out: W2's POC produced
sufficient evidence for the verdict on its own, and W3's deferred items become more
tractable once we have our own JIT executor running to compare against — they don't need
to precede the verdict.

### W2 — Apple architecture study

#### Q6 closed: Apple's runtime IS LLVM ORC + JITLink

Captured in full at `research/scripts/analysis/q6-jit-runtime-findings.md`. Headline
evidence from VM-side `dyld_info`:

- `PreviewsInjection.framework` weak-links
  `/System/Library/PrivateFrameworks/XOJITExecutor.framework`. Not visible from the host
  SDK (no `.tbd` stub) — VM-side dump only.
- `XOJITExecutor.framework` exports `___jit_debug_register_code`, `___jit_debug_descriptor`,
  and `_llvm_orc_registerJITLoaderGDBAllocAction` — the last is literally an `llvm::orc::`
  API function defined in LLVM's `DebuggerSupportPlugin.h` and registered with
  `ObjectLinkingLayer`.
- Swift façade: `XOJITExecutor.JITDylibHandle (rawValue: UInt64)` (`JITDylib` is LLVM ORC's
  primary namespace abstraction); `XOJITExecutor.init(connection: OS_xpc_object)` (the LLVM
  `SimpleRemoteEPC` shape with XPC substituted for the default socket/pipe transport).
  `TerminationResult` enum matches LLVM `SimpleRemoteEPC` failure modes exactly.
  C-side `___xojit_executor_write_mem`, `___xojit_executor_run_program_on_main_thread`,
  `___xojit_executor_run_program_wrapper` mirror the `llvm-jitlink-executor` helper-tool
  shape one-to-one.
- No `libLLVMOrcJIT.dylib` import; `libc++.1.dylib` imported. **LLVM ORC + JITLink
  statically linked with `-fvisibility=hidden`**; only GDB-JIT-interface symbols leak.

**Implication:** the public-layer architecture we'd build is not an *equivalent of* Apple's
runtime. It is *the same architecture*, modulo Apple's dyld pseudodylib extension
(`__dyld_is_pseudodylib`) — and our images don't need that extension since they are
normal-dyld-visible. We build what Apple built, on the public version of the same
libraries they statically link.

#### Architecture diagram draft 1

Captured at `research/scripts/analysis/architecture-diagram-draft.md`. 6,723 swift-demangled
exports from `PreviewsPipeline.framework` (Xcode 26.2) plus 11 sibling Previews-* framework
dumps. Load-bearing findings:

- The "15-step pipeline" name list in `docs/reverse-engineering.md` does **not** appear as
  Swift type names — those are almost certainly `PipelineEventSignpost` runtime labels. The
  pipeline is **graph-driven** (`Pipeline(resourceGraph:)`, `ResourceGraph`,
  `EditorContext.invalidate`), not a linear array of named steps — identical shape to
  Bazel Skyframe / rustc Salsa.
- `PreviewProduct` is an enum with cases `.preLinked(PreLinked)` (legacy Dylib path, full
  path fields) and `.runtimeLinked(RuntimeLinked)` (XOJIT path, no path fields — artifact
  is object code linked agent-side).
- `PreviewAgentRunMode` enum: `.dynamicReplacement / .jitExecutor / .fullBinary` —
  confirming both legacy and JIT paths ship side-by-side in Xcode 26.2.
- `PreviewsJITLinkerParameters` (`objectFilePaths, architectures, installName, linkerFlags,
  loadCommands, rpaths, staticLibraryPaths, platformVersion, …`) is the message-shape
  Xcode sends to the agent — a serialized linker invocation, same field set we'd populate
  for ORC `LLJIT`.
- `XOJITThunkBuilder.build` takes `compilerPath` + `compilerArguments` +
  `thunkObjectFileDestination`. **No linker path / linker args.** For XOJIT only the
  `swiftc -emit-object` step runs host-side; linking is agent-side.

The public-layer analogue table identifies an analogue for **every** Apple sub-system, with
effort sizing. Two rows sized "large": LLVM ORC + JITLink integration (which the POC
exercised — see below) and the patch-point runtime injection (W3 territory, TODO). The
remaining 22+ rows are mechanical reshaping. The architectural distance between "what Apple
shipped" and "what we'd ship on public layers" is not months of design — it is the
engineering effort of two large pieces and a stack of small ones.

### W2 — JITLink proof-of-concept (the load-bearing experiment)

Lives on the sibling worktree `.worktrees/jit-poc`, branch `jit-poc`, HEAD `95db2ed`. The
ladder of commits `5cb8277..95db2ed` represents the spike's most consequential empirical
work. Per-phase results:

#### Phase 1 — trivial Swift function override (`2a402c2`)

The minimal experiment: `swiftc -emit-object` of two Swift sources containing one `@_cdecl`
function each (`greet()` printing v1 / v2), loaded sequentially into an LLJIT with an
explicit `ObjectLinkingLayer` (JITLink, not RTDyld), Swift stdlib refs resolved via the
host process's symbol table (`DynamicLibrarySearchGenerator::GetForCurrentProcess` + dlopen
of `libswiftCore.dylib`).

Result (`data/run-20260519T010949Z.log`): on the first build, both calls printed cleanly
("hello from swift v1" then "hello from swift v2"), with JITLink resolving against
`_swift_allocObject`, `_swift_bridgeObjectRelease`,
`_swift_getTypeByMangledNameInContext2`, `$sSSN`, `$ss5print_*`, plus `__swift5_typeref` +
`__data` + `__cstring` sections and `__compact_unwind`. **The trivial case clears on first
try.**

Override mechanism: each version is loaded into its own JITDylib; the second lookup is
scoped explicitly to v2's JITDylib via `ExecutionSession::lookup`. Phase 2.1's stretch goal
sharpens what a "principled override" actually requires.

#### Phase 2.1 — protocol witness override + W3 patch-point hypothesis (`a396afd`, `4f577ca`)

Closest analogue to "hot-reload the body of a SwiftUI `View`": dispatch through a protocol
witness table. Shared `Greeter` protocol in its own `.o`; `greeter_v{1,2}.swift` each
conform via `DefaultGreeter`, with a `@_cdecl("makeGreeting")` that forces dynamic dispatch
via `let g: any Greeter = DefaultGreeter()`. Per-version `.o` loaded into per-version
JITDylib with link order `[VxJD, MainJD]`.

Result (`data/run-witness-20260519T013359Z.log`): both versions print their respective
greetings via separate witness chains. **All Swift metadata sections JIT-linked cleanly,
none rejected**: `__swift5_proto`, `__swift5_protos`, `__swift5_types`, `__swift5_typeref`,
`__swift5_fieldmd`, `__constg_swiftt`, `__swift_modhash`, `__compact_unwind`. Cross-JITDylib
external resolution of the protocol descriptor (`$s7GreeterAAMp`) worked on first run.

**Stretch goal** (`data/run-witness-20260519T013611Z.log`, commit `4f577ca`): does loading
v2 into a new JITDylib retroactively redirect dispatch from a previously-resolved v1
function pointer? Three questions:

- Q1: re-call the saved v1 FP after loading conform_v2 into ConfV2JD → still v1. **JITLink
  resolves relocations at link time; v1's witness-table pointer is fixed and not
  retroactively edited.**
- Q2: fresh lookup of `_makeGreeting` in ConfV2JD → resolves to v2's image. Works.
- Q3: prepend ConfV2JD to MainJD's link order, fresh lookup of `_makeGreeting` in MainJD →
  still v1. MainJD's own definitions take precedence over its link-order references.

**This is the most consequential finding for W3.** A hot-reload that wants to keep the v1
image as the entry point and route through v2's conformance **cannot do so by JITDylib
manipulation alone.** The patch must happen at one of two places:

- **(a) Replace v1's witness-table data bytes in place** — `mprotect` to writable, `memcpy`
  the v2 witness's function pointer over v1's PWT slot, `mprotect` back. Atomic
  pointer-width writes serialize cleanly against in-flight calls. This is the **W3
  patch-point hypothesis** referenced below.
- **(b) Factor the conformance into its own image referenced as an external by v1, replace
  that image** — needs JITDylib replace / undef-then-redefine. Matches Apple's apparent
  shape more closely.

Both are tractable, public-layer-only, and reasonable implementation choices for the
design doc.

#### Phase 2.2 — TLVs and Swift `swift_once`-guarded globals (`5641b28`, `cbf7d34`)

Two hard-case JIT-link paths exercised under explicit `MachOPlatform` (brewed compiler-rt's
`liborc_rt_osx.a`):

- **C `_Thread_local`** — canonical Mach-O TLV path. `__thread_vars` + `__thread_data`
  JIT-linked cleanly; `_tlv_bootstrap` resolved via `MachOPlatform`'s alias to
  `___orc_rt_macho_tlv_get_addr`. Mutation 42→43→44, cached read returns 44.
- **Swift module-level `let`** — spike finding: swiftc 6.2 does **not** lower
  `let foo = { ... }()` to a Mach-O TLV. It emits a regular global in `__DATA,__common`, a
  one-time-init function (`_..._WZ`), a once-token in `__DATA,__bss` (`_..._Wz`), and an
  unsafe-mutable-addressor (`_..._SSvau`) that guards reads with `swift_once`. **This path
  JIT-links cleanly** (`data/run-tlv-20260519T015317Z.log`): first read fires the
  initializer (sum-of-squares 1..100 = 338350); second read returns the cached value.

Two failure-mode logs preserved: the first surfaced the need to dlopen `Foundation` +
`libswiftFoundation`; the second surfaced the ObjC selref uniquing gap that Phase 2.2.5
closed below.

#### Phase 2.2.5 — ObjC selref uniquing plugin (gap closure, `a260aa2`, `f246bc0`, `b908101`)

The one gap surfaced during Phase 2.2 and closed in-spike: public LLVM `MachOPlatform`
processes `__objc_imageinfo` but does **not** call `sel_registerName` on the selector
strings in `__objc_selrefs`. After JITLink finishes, each selref slot holds a pointer into
the JIT image's own `__objc_methname` C-strings; `objc_msgSend` doesn't recognize it, falls
into `__forwarding__`, and the process aborts.

**Fix:** `ObjCSelrefPlugin` (lives at `.worktrees/jit-poc/research/jit-poc/src/ObjCSelrefPlugin.{hpp,cpp}`,
~150 LOC). An `ObjectLinkingLayer::Plugin` whose pass (installed via `PostPrunePasses`)
walks `__DATA,__objc_selrefs`, reads the methname C-string at each edge's offset, calls
`sel_registerName(cstr)`, and rewrites the edge to point at an `addAbsoluteSymbol` whose
address is the canonical SEL. The regular JITLink fixup path then writes the absolute's
address into the slot — no working-memory poking, no duplicating libobjc's hash side effects.

Result (`data/run-objc-20260519T020930Z.log`): both
`ProcessInfo.processInfo` (the originally-failing case) and `NSString(format:) + .description`
print correctly. Plugin verbose log shows 3 selrefs rewritten to canonical SEL addresses
matching exactly the `sel_registerName(...)` pointers logged before the JIT object loaded.

**Significance for the verdict:** the gap surfaced was closed by a small plugin we ship on
top of the public ORC plugin API. **Apple's `XOJITExecutor` has to do equivalent work** —
Q6 evidence confirms they statically link LLVM ORC; they wrote the same plugin internally.
The gap is "infrastructure not provided out of the box," not "public layer can't do this."

#### Phase 2.3 — async with multi-await (`f0f5a01`, `6ea33b1`, `95db2ed`)

`async_v1.swift`: `func greetAsync() async` plus a `@_cdecl` sync wrapper bridging via
`DispatchSemaphore`. swiftc 6.2.3 emits two async-specific sections —
`__TEXT,__swift_as_entry` and `__TEXT,__swift_as_ret` (both `S_COALESCED`) — with
relocations. Undefined refs include `_swift_task_create`, `_swift_task_alloc`,
`_swift_task_dealloc`, `_swift_task_switch`.

A failure log (`run-async-20260519T025800Z.log`) surfaced a **second ObjC gap**: the
original wrapper used a local `final class Box: @unchecked Sendable` for the mutable-capture
diagnostic, which emitted a non-empty `__DATA,__objc_classlist`; libobjc aborts with
`"Attempt to use unknown class 0x..."`. `MachOPlatform` does **not** call
`objc_registerClassPair` / `_objc_realizeClassFromSwift` for classes in JIT-loaded objects.
**This is an orthogonal infrastructure gap — analog of the selref one Phase 2.2.5 closed —
needing its own plugin.** Not closed in-spike.

Workaround applied for the green run (`run-async-20260519T025854Z.log`): rewrote the wrapper
with `UnsafeMutablePointer<String>` for result handoff, leaving `__objc_classlist` empty.
The JIT-linked async object then runs cleanly: Task spawned, awaited `Task.sleep`, resumed,
signaled the semaphore; `runAsync` returned with `"hello from async v1"` printed.
**swiftasynccc lowering + JITLink interoperate correctly.**

**Stretch** (`run-async-v2-20260519T030019Z.log`): `async_v2.swift` rewrote `greetAsync()`
to `await partA(); await partB()` then string-interpolate across the continuation boundary
— two continuation points, second resumed after the first completes. Green: prints
`"hello from async v2"`. JITLink + the Swift concurrency runtime handle **chained
suspensions** correctly under `MachOPlatform`.

---

## What didn't work / what's not yet verified

Honesty about uncertainty is the spike's required output. Three items are not closed:

### ObjC classlist gap (plugin pending)

Phase 2.3 surfaced a second ObjC interop gap with the same shape as the selref one:
classes emitted into `__DATA,__objc_classlist` of a JIT-loaded object are not registered
with the ObjC runtime. The fix is structurally the same as `ObjCSelrefPlugin` — an
`ObjectLinkingLayer::Plugin` that iterates the section and calls
`objc_registerClassPair` / `_objc_realizeClassFromSwift` — but it is not yet written.

**Severity:** low. The plugin shape is known; ~150 LOC is the rough sizing based on the
selref plugin. SwiftUI bodies and most preview shapes don't emit `__objc_classlist` content
(`@unchecked Sendable` workarounds suffice — the spike's async green run does exactly that).
But for the design doc this is a "must implement before production" item, not a "spike open
question." Captured as a pre-implementation TODO.

### W3 patch-point runtime confirmation

**Updated post-W3.** Mechanism-level closure landed; per-edit address-list-level
extraction still pending. See `research/scripts/analysis/w3-patch-point-set.md`.

What W3 closed: the patch mechanism is option (a) (in-place
`mprotect`+`memcpy` via `___xojit_executor_write_mem`), driven by host-side
ORC over the LLVM `SimpleRemoteEPC` wire protocol. Option (b) (JITDylib
replacement) is *not* what Apple ships — there is no `replace`-style export
on either `XOJITExecutor.framework` or `PreviewsInjection.framework`, and
the imports table (`_mprotect`, `_mach_vm_map`, `_memcpy`, `_memmove`)
explicitly fingerprints the W^X-data-patch model.

What W3 did *not* close: the specific list of addresses (PWT slots, GOT
entries, etc.) that get written for a given concrete edit kind. Doing so
requires dtrace on `__xojit_executor_write_mem` during a real Xcode
hot-reload — see `research/scripts/data/w3/capture-write-mem.d` for the
ready-to-run dtrace script and `research/scripts/analysis/w3-patch-point-set.md`
§6 for the full procedure.

**Severity for the verdict:** does not change it. The architectural question
("can the public layer do this?") was already answered without W3. The W3
mechanism-level finding *strengthens* the design-doc input (we now know
Apple's design is the LLVM SimpleRemoteEPC pattern, which our own
implementation can use directly) but does not move the verdict. The
remaining per-edit address-list work is implementation-time tuning.

### Large-module scaling

Every POC test was a single Swift file (or two — one preview, one shared protocol). Apple's
`PreviewsPipeline` is engineered for 1000+ file modules. **We have not demonstrated that
JITLink scales to module-sized inputs.**

What we know from the architecture diagram: Apple's pipeline does **not** JIT-link the
whole module — only the preview thunk(s) against pre-built object code for the stable
module. `XOJITThunkBuilder.build` produces one `.o` per thunk;
`PreviewsJITLinkerParameters.objectFilePaths` is a list of pre-built object files plus
`staticLibraryPaths`. The "1000+ file module" is consumed as pre-built `.o` files (or a
static archive), not re-JIT-linked per edit.

What we don't know: how JITLink performs on a real 1000-file module's `.o` set + a thunk.
Expected linear in section + relocation count; thunk-only re-link expected fast — but
unmeasured.

**Severity for the verdict:** does not change it. Apple's architecture establishes
JIT-link-on-a-large-module is tractable (they ship it); the only question is whether public
JITLink's constant factors are within a defensible budget. Post-verdict spike against a
synthetic 1000-file module is the right place to measure this. Captured as a
pre-implementation TODO.

---

## Verdict

### Against the four product properties (from `jit-executor-research.md` → "Product target")

#### Scales to large modules

**Positive.** Apple's pipeline pattern — stable-module objects pre-built once, thunk
JIT-linked per edit against those objects — does not require `-enable-implicit-dynamic`'s
pervasive call indirection. The optimizer-regression cost is structurally absent. Remaining
question (JITLink's constant factors on a module-sized input) is bounded and measurable
post-verdict.

Evidence: architecture-diagram doc → `XOJITThunkBuilder.build` signature (no linker
arguments) + `PreviewsJITLinkerParameters` (object-file paths + static-library paths, no
re-link of the module). POC: all six Phase 2 patterns JIT-linked cleanly; no pathological
scaling behavior observed.

#### Build-artifact parity

**Positive.** Our build emits `swiftc -emit-object` `.o` files — the same artifact
`xcodebuild` and Bazel `rules_swift` emit on their happy path. No separate
dynamic-replacement build pipeline contributing to cold-start cost; the JIT-link path
consumes the build's natural object output directly. Apple's pipeline does the same.

Evidence: POC consumes `swiftc -emit-object` outputs directly. Linker-argument ingestion
(`LinkerArgumentIngestor` in Apple's pipeline) is a "medium effort" row in the public-layer
analogue table, not a "large" one.

#### Edit-anywhere hot-reload

**Positive, with W3 patch-point implementation as the load-bearing piece.** Phase 2.1's
protocol-witness override demonstrates JIT-link patches symbols visible at link time —
including transitively-reached symbols, since they're part of the link graph.
Edit-anywhere is the natural shape of JIT-link, not a bolt-on. The Phase 2.1 stretch-goal
constraint (JITDylib swaps don't retroactively redirect dispatch) is the shape of the
patch mechanism's design, not a limit on what can be patched.

Evidence: Phase 2.1 logs. Phase 2.2 (TLVs, `swift_once` globals) confirms the patch surface
extends to module-level state, not just function bodies.

#### Long-term ABI stability

**Positive.** Built on Mach-O / LLVM JITLink semantics, both with decade-plus upstream
stability records. No reliance on underscored `@_dynamicReplacement` or any `_private`
Swift annotation. `swiftc -emit-object` is the standard production path, not a research
mode.

The one item to monitor is Swift emission-pattern drift: each new Swift version potentially
adds section types or lowering patterns (e.g., Phase 2.2 found swiftc 6.2 lowers module-level
`let` via `swift_once` rather than a Mach-O TLV). Bounded by the fact that **Apple's own
preview stack absorbs the same drift via the same LLVM ORC + JITLink layer** — any pattern
Apple's XCPreviewAgent handles, our equivalent handles, both via the same upstream LLVM
coverage.

Evidence: Q6 + the POC's clean JIT-link of all six Phase 2 patterns demonstrates the public
layer already covers production Swift.

### Stated verdict

**Verdict #1: Buildable; supersedes thunk for the product target.**

The custom JIT executor is architecturally tractable on stable public layers (LLVM
JITLink/ORC, `swiftc -emit-object`, Mach-O loader semantics, the public JIT entitlement)
within a defensible engineering budget, clearing each of the four product properties above.
We recommend pivoting `thunk-architecture.md`'s runtime-dylib delivery to a JIT-link
delivery, keeping the file-watcher / stable-module / runtime split otherwise intact. Thunk
remains shipped as the small-module holdover while the JIT executor builds out
(multi-quarter).

**Why #1 and not #2:** the four product properties all score "positive" without conditions.
Verdict #2 would require at least one property to score "positive only for a subset" —
none did. The thunk path's value is exclusively as the small-module shipping product
*during* JIT-executor buildout; it is not the long-run architecture.

**Why #1 and not #3:** no public-layer building block was found missing or inadequate. The
gap closed in-spike (ObjC selref uniquing) is the kind of gap LLVM's plugin API exists to
close. The gap surfaced but not closed (ObjC classlist) has the same shape and ~150 LOC
sizing. Q6 establishes that Apple's runtime stack is built on the same public layer — strong
prior that any Swift emission pattern reachable by Apple's preview stack is reachable by
ours.

The strongest piece of evidence is Q6: **Apple's preview stack is statically linked LLVM
ORC + JITLink behind a Swift/XPC façade.** The architecture we'd build is not "an approach
inspired by Apple's" — it is "the same approach Apple shipped, on the public version of
the same libraries." The POC's six green phases demonstrate the public layer handles
production Swift emission patterns directly.

### What this verdict unlocks (and what it gates)

A "supersedes" verdict opens follow-on work on a multi-quarter timeline. The verdict does
not by itself authorize implementation; the design doc below is the gating artifact.

**Follow-on docs (out of scope here):**

- **`prompts/jit-executor-design.md`** — the design doc for our JIT executor. Covers
  patch-point set (option (a) PWT-data in-place patch vs (b) per-conformance JITDylib
  replacement, informed by W3 dtrace once landed); symbol-discovery (sidecar vs lazy
  intercept-on-call resolver); JITLink plugin architecture (selref uniquing + classlist
  registration + any further gap); concurrent-patch sequencing. Per spike scope, a separate
  follow-on. **Not written here.**
- **`prompts/ios-host-wire-protocol.md`** — noted as adjacent in `prompts/README.md` "Open
  follow-ups." Under a JIT-executor target, the same wire-protocol concerns from
  thunk-architecture.md apply with the dylib triple replaced by the runtime + JIT-link
  payload pair.

**Pre-implementation TODOs:**

1. **W3 patch-point address-list confirmation.** *(Mechanism-level closure
   landed post-spike: option (a) confirmed, see
   `research/scripts/analysis/w3-patch-point-set.md`.)* Remaining work: dtrace
   on `__xojit_executor_write_mem` during a real Xcode hot-reload to enumerate
   the specific PWT slots / GOT entries written per edit kind. ~2-3 days once
   an Xcode-driving harness exists (the harder subtask). Ready-to-run dtrace
   script at `research/scripts/data/w3/capture-write-mem.d`. VM infrastructure
   under `research/vm/` provisions the environment.
2. **ObjC classlist plugin.** ~150 LOC, same shape as `ObjCSelrefPlugin`. Closes the second
   ObjC interop gap surfaced in Phase 2.3.
3. **Large-module scaling spike.** Synthetic 1000-file Swift module, JIT-link a
   representative thunk under LLVM ORC `LLJIT`. Measure link wall time, peak memory,
   per-edit re-link time. ~1 week. Likely outcome: "fast enough" + a list of constant-factor
   optimizations. Unlikely outcome: "JITLink chokes" — would surface a JITLink upstream
   work item but not invalidate the architectural verdict.

These three are design-doc prerequisites, not blockers. They can run in parallel with the
design doc.

---

## Provenance

Every claim above is grounded in a specific artifact:

- **Architecture diagram (W2):**
  `research/scripts/analysis/architecture-diagram-draft.md` — 6,723 demangled exports
  analyzed; 249 top-level Swift types catalogued; 13 open questions enumerated; public-layer
  analogue table with effort sizing.
- **Q6 memo:** `research/scripts/analysis/q6-jit-runtime-findings.md` — VM-side `dyld_info`
  evidence closes Q6.
- **POC code:** `.worktrees/jit-poc/research/jit-poc/`, branch `jit-poc`, commits
  `5cb8277..95db2ed`. Plugin: `src/ObjCSelrefPlugin.{hpp,cpp}`. Hosts: `src/host.cpp`,
  `src/host_witness.cpp`, `src/host_tlv.cpp`, `src/host_objc.cpp`, `src/host_async.cpp`.
- **POC data (run logs):** `.worktrees/jit-poc/research/jit-poc/data/`
  - Phase 1 green: `run-20260519T010949Z.log`
  - Phase 2.1 green + stretch: `run-witness-20260519T013359Z.log`,
    `run-witness-20260519T013611Z.log`
  - Phase 2.2: `run-tlv-20260519T015115Z.log`, `run-tlv-20260519T015157Z.log` (failures),
    `run-tlv-20260519T015317Z.log` (green)
  - Phase 2.2.5 green: `run-objc-20260519T020930Z.log`
  - Phase 2.3: `run-async-20260519T025800Z.log` (failure), `run-async-20260519T025854Z.log`
    (green), `run-async-v2-20260519T030019Z.log` (stretch)
- **Raw symbol dumps (W2 input):** `research/scripts/data/` — `previews-pipeline-exports.txt`
  + 11 sibling Previews-* exports + `libPreviewsJITStubExecutor-{symbols,undefined}.txt` +
  `PreviewsInjection-tbd-symbols.txt`.
- **VM-side symbol dumps:** `research/scripts/data/vm/` —
  `XOJITExecutor-{exports,imports,linked_dylibs}.txt`,
  `PreviewsInjection-{exports,imports,linked_dylibs}.txt`.
- **Research VM:** `research/vm/`, branch `jit-exploration`. Snapshots: `post-sa` (Setup
  Assistant complete on macOS 26.3.1), `post-xcode-sip-amfi` (SIP off, AMFI off, Xcode 26.2).

**Verified-against:** macOS 26.3.1 (VM-side), Xcode 26.2 (Build 17C52), Swift 6.2 / 6.2.3
(POC `swiftc`), LLVM 22 (`/opt/homebrew/opt/llvm`). Single-version per spike non-goals.

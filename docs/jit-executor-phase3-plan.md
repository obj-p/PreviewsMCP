# JIT Executor — Phase 3 plan and state

Living plan for Phase 3, "SwiftUI session-lifecycle integration + hot-reload."
Resume from here across sessions. Update it as work lands. Phase 1 (issue #183)
is on `main` via PR #185; Phase 2 via PR #186. Phase 3 tracks issue #189 on
branch `jit-phase3-session-integration` (PR #190).

## Sources of truth

- `docs/jit-executor-phase1-plan.md`, `docs/jit-executor-phase2-plan.md`
  (landed state, discoveries, gotchas).
- `prompts/jit-executor-design.md` §§2, 4, 5, 6, 7, 8.Phase-3 (on
  `previews-research`).
- Auto-memory: `project_jit_inprocess_harness`, `project_jit_dynamic_replacement`,
  `project_jit_spike_outcome`.
- Branch: `jit-phase3-session-integration` (off `main` at `4de49e2`).

## Goal

Wire the JIT executor into PreviewsMCP's session lifecycle. The existing
FileWatcher + Compiler + SessionResolver pipeline routes **structural** edits to
JIT-link instead of thunk-rebuild; **literal-only** edits stay on the
thunk/`DesignTimeStore` path (`LiteralRegionClassifier` already classifies
them). Run a real SwiftUI `View` body in the agent and render it, then drive
edits without restarting the daemon. The jump from Phase 2: Phase 2 only ran
nullary `@_cdecl` functions via `runAsMain`; Phase 3 runs a real `View` body and
renders, so the agent needs a SwiftUI/render harness and a calling surface
beyond `runAsMain`. The deferred SP5 (richer `SessionResolver`/JIT API) lands
here.

## Key decision (amended 2026-06-04): respawn-on-cap (capped-persistent)

Updates use **one persistent agent + a fresh `JITDylib` per edit**, with a
**background respawn every ~100 generations** (the cap). Not in-place
`write_mem` patching. This amends the original **respawn-first** decision
(below) after the generation-soak (`research/jit-poc/data/
run-soak-20260604T024308Z.log`, previews-research): across 500 generations
latency stays flat (link/render medians ~0.4ms; conformance scans do not slow),
while RSS leaks linearly ~87KB/generation because `__swift5_*` metadata cannot
deregister. The cap bounds the leak at ~+9MB and amortizes the ~70ms respawn
warmup to ~0.7ms/edit. Net per-edit: **~167ms capped-persistent vs ~233ms
respawn-per-edit**. Respawn remains the cleanup mechanism — just on the cap,
not on every edit. The original rationale and evidence:

- **Why respawn.** The Swift runtime has no deregister for `__swift5_proto` /
  `__swift5_types` (Phase 1 SP0d-D). A long-lived agent that JIT-links a new
  image per edit leaks metadata registrations permanently. Respawn (kill the
  agent, spawn a fresh one that loads the new image) is the clean teardown for
  exactly that leak.
- **Matches Apple.** The W3 empirical capture (design §2 "Per-edit address-list
  capture — RESOLVED") found Apple respawns `XCPreviewAgent` for every edit kind
  tested, with zero `write_mem`. The §2 patch-point table is the
  static-analysis universe for a future in-place path, not the Phase 3 path.
- **State.** Preserving runtime `@State` across a structural edit is **not** a
  Phase 3 goal (acceptance is latency-only). `DesignTimeStore` holds only
  design-time literal values, not runtime `@State`, so literal-state continuity
  is kept by re-seeding the store after respawn; runtime `@State` is lost on
  structural edits, same as Apple.
- **Provenance of the alternative.** The §5/§6 in-place `write_mem` +
  Begin/End/cancelUpdate handshake is the doc's *original* design, written
  before the W3 respawn evidence landed (git: design doc `c8056de` precedes the
  capture `76a7b34`). It is kept as a later, clearly-scoped chunk (P3.3), added
  only if it earns its keep. Phase 2 already proved the `write_mem` publish
  mechanism (P2.5).

## Assumptions

- The Phase 2 remote `JITSession` (socketpair + `SimpleRemoteEPC` +
  `SwiftEntrySectionPlugin` + per-session agent) is reused unchanged in shape.
- `Compiler.compileObject(source:moduleName:extraFlags:)` already emits the `.o`
  the JIT path needs.
- The macOS preview entry symbol is a `createPreviewView`-style `@_cdecl`
  returning a retained `NSHostingView` (see `BridgeGenerator`, the daemon render
  path in `PreviewsMacOS/HostApp.swift`).

## Unknowns (each a verification gate)

- **U-A:** can a spawned headless agent host `NSApplication` (`.accessory`) and
  render an `NSHostingView` offscreen to a bitmap, the way the daemon does
  today? (Gate for P3.1b.)
- **U-B (= Phase 1 U2):** does the Swift calling convention hold when we call a
  real `View`-body entry that returns a retained pointer, marshaled onto the
  agent's main thread, versus the trivial nullary functions Phase 2 ran? (Gate
  for P3.1b.)
- **U-C:** does respawn within a live daemon session re-establish the agent and
  re-seed `DesignTimeStore` fast enough to hit the design's <200ms structural
  target on a small module? (Gate for P3.2/P3.4.)
- **U-D:** what is the minimal seam in `PreviewSession`/`HostApp` to route
  structural edits to the JIT path without disturbing the literal-only
  `DesignTimeStore` fast path? (Gate for P3.4.)

## Subproblems and verification criteria

### P3.1 — Agent SwiftUI render harness

The big-jump risk. Split in two.

#### P3.1a — run a real SwiftUI `View` body in the agent — DONE
The agent `dlopen`ed only Core/Concurrency/Foundation/Dispatch, so a JIT-linked
object referencing SwiftUI failed to materialize ("Symbols not found" for
`SwiftUI.View` / `SwiftUI.Text`). Added a SwiftUI `dlopen`
(`/System/Library/Frameworks/SwiftUI.framework/SwiftUI`, `RTLD_GLOBAL`; AppKit
pulled transitively by dyld) so the process-symbol generator resolves SwiftUI
symbols. Fixture `swiftui_probe.swift` is a trivial `View` whose `body` builds a
`Text`; the remote test links it in the agent, evaluates the body, returns 7.
AppKit-free and main-thread-free on purpose, to isolate one unknown.
- **Verify (met):** `runsSwiftUIViewBodyRemotely` returns 7. 26 tests green in
  parallel, zero orphan agents. Commit `1fe37b3`.

#### P3.1b-i — main-thread invoke surface + `NSHostingView` construction — DONE
Restructured the agent so the EPC server runs on a background thread and the
main thread runs a CoreFoundation run loop (`CFRunLoopRunInMode` after
`NSApplicationLoad()`), freeing the main thread for AppKit. Added an executor
wrapper `__previewsmcp_run_on_main` (a bootstrap symbol) that `dispatch_sync`s a
JIT'd function onto the main queue and returns its `int32_t`, mirroring Apple's
`run_program_on_main_thread`. Host side: `previewsmcp_jit_session_run_on_main`
fetches that bootstrap symbol and calls it via
`callSPSWrapper<int32_t(SPSExecutorAddr)>`; Swift `runOnMain(symbol:)`. Fixture
`hosting_probe.swift` builds an `NSHostingView` on the main thread and returns 1
if its `fittingSize.width > 0`.
- **Verify (met):** `buildsHostingViewOnMainThreadRemotely` returns 1. Full
  suite 27 tests green, 12/12 parallel runs clean, zero orphan agents. U-A
  (Cocoa hosts in a headless agent) and U-B (Swift `View` entry on the main
  thread) retired for the construction case.

**Discovery (pre-existing race, fixed here):** moving the server off the main
thread changed timing enough to surface a latent data race. Native-target init
(`LLVMInitializeNativeTarget` / `…AsmPrinter`) ran under two separate
`std::call_once` flags, one in the in-process `makeJIT` and one in
`remote_session_create`. A concurrent first-time in-process + remote session
create then mutated LLVM's global `TargetRegistry` linked list from two threads,
corrupting it: `lookupTarget` either span forever (a hang, surfaced as agents
never torn down holding the test's inherited stdout pipe open, the P2.4 EOF
failure mode) or tripped a `SmallVector` assert. Fixed by unifying both paths
behind one shared `initNativeTargetOnce()` once-flag. Teardown is unchanged
(`session_destroy` resets the `LLJIT` then `SIGKILL`s the agent).

#### P3.1b-ii — render the view to a bitmap — DONE
Fixture `render_probe.swift` renders a known-color SwiftUI view via
`ImageRenderer` (`MainActor.assumeIsolated`, since `ImageRenderer.cgImage` is
main-actor), samples the center pixel from the `CGImage`, and returns it packed
as `Int32`; the test drives it through `runOnMain` and asserts the channels are
red. `ImageRenderer` was chosen over an `NSHostingView`-in-window snapshot
because it rasterizes headless without a window. Retires the rendering half of
U-A: the agent rasterizes a JIT-linked SwiftUI view to pixels.

**Discovery (the load-bearing one): U-A finally bit, and the slab is the fix.**
Bringing real SwiftUI into the agent surfaced three `EXC_BAD_ACCESS` crash modes,
all reading ~4 KB **past a mapped region** while the Swift/SwiftUI runtime walks
JIT'd type metadata (`swift_conformsToProtocol…`, AttributeGraph
`LayoutDescriptor` building, `NSHostingView` teardown). Root cause: the **remote**
path built `ObjectLinkingLayer(es)` with the **default per-allocation mmap**
memory manager, which scatters each section into its own page-rounded mmap;
reading one entry past a section lands in the unmapped gap right after it. This
is exactly Phase 2's deferred unknown **U-A** ("revisit only if a future large
object trips it") and the same class as Phase 1's unwind-slab gotcha. The six POC
scenarios were small enough to dodge it; SwiftUI's heavy metadata walking trips
it. **Fix (first attempt, REVERTED — see below):** a **contiguous slab** via the
shared-memory mapper (`SharedMemoryMapper` + `MapperJITLinkMemoryManager`); the
agent already hosted `ExecutorSharedMemoryMapperService`. With the slab the
section walks stay in-bounds and the suite was 40/40 green across parallel runs.

#### P3.1b-iii — the shared-memory slab is macOS-incompatible; anonymous mapper instead — DONE
The shared-memory slab worked for ~80 runs, then **every** remote session began
failing with `Failed to materialize symbols { (<Platform>,
{ ___mh_executable_header, ___dso_handle }) }: Permission denied`, and it did not
recover across a reboot. Root cause: the orc-rt `ExecutorSharedMemoryMapperService`
makes JIT memory executable with `mprotect(...PROT_EXEC)` on `MAP_SHARED` memory,
which **macOS denies (EACCES)**. This is standard macOS hardening, confirmed with
a standalone C program: `mmap` exec-from-start on shared memory is allowed, the
`mprotect` transition is not, in every context (unsigned, signed with
`allow-jit` / `allow-unsigned-executable-memory` / `get-task-allow`, under lldb).
The earlier 80 green runs were the permissive window; it closed mid-session and
stayed closed. **This was an expensive diagnosis** (it also masqueraded as a
"Compiler flags" problem during a confounded P3.2 attempt, since every variant
failed for the same shared-exec reason). NOTE: do not `pkill -9` loop hundreds of
JIT agents while debugging.

How Xcode gets around it: Apple's `XCPreviewAgent` carries **no** JIT entitlement
(only `get-task-allow`, same as ours), and `XOJITExecutor` populates the agent's
**anonymous** executable memory over the wire (`___xojit_executor_write_mem`),
never shared memory. `mprotect`-exec on anonymous memory is permitted.

**Fix (final):** replace the shared-memory slab with a **contiguous slab backed
by anonymous executor memory**, matching Apple. New code, no `third_party` patch:
- Agent: a mapper service (`__previewsmcp_anon_reserve` = anonymous `mmap`;
  `__previewsmcp_anon_initialize` = `memcpy` the wire-transferred content +
  `mprotect` + `InvalidateInstructionCache` + run finalize actions;
  `deinitialize` = no-op; `release` = `munmap`).
- Host: `PreviewsAnonymousMapper` (a `MemoryMapper` that keeps a local working
  buffer and ships segment content over the wire) driving
  `MapperJITLinkMemoryManager` for one contiguous reservation per session.

Two load-bearing details: (1) the agent must `InvalidateInstructionCache` after
writing exec segments, or ARM64 executes stale icache (intermittent garbage-
execution crash); (2) it **discards deallocation actions** — the JIT image is
process-lived in the respawn model (Phase 1 D3), so running JIT'd destructors at
teardown is unnecessary and was crashing (`mutex` EINVAL in a JIT'd dealloc
action). With both, U-A is fixed via anonymous contiguity and **the prior
post-result SwiftUI-teardown crashes also vanished**.
- **Verify (met):** suite **15/15 green** across parallel runs, zero agent
  crashes, zero orphans. Commit `a8d5909`.

**Two supporting fixes surfaced while diagnosing (asserts build, parallel
runner):**
- **Host target-init race (pre-existing).** `LLVMInitializeNativeTarget` ran under
  two separate `call_once` flags (in-process `makeJIT` and `remote_session_create`).
  A concurrent first-time in-process + remote create corrupted LLVM's global
  `TargetRegistry` (hang via `lookupTarget` spin, or `SmallVector` assert). Unified
  behind one `initNativeTargetOnce`. (Also serialized the in-process
  `LLJIT::initialize` with a mutex; `ORCPlatformSupport::initialize` raced across
  the shared in-process `LLJIT`.)
- **Agent teardown use-after-free (my regression from P3.1b-i).** The restructure
  destroyed the `Server` on the background thread right after `waitForDisconnect`,
  while the transport's listen thread was still in `handleDisconnect`. Fixed by
  `std::_Exit(0)` on disconnect (the host `SIGKILL`s the agent anyway, so clean
  unwinding has no value and is racy).

**Verify (met):** `rendersViewToBitmapOnMainThreadRemotely` returns a red pixel;
suite 40/40 green across parallel runs, zero orphan agents.

**Teardown crashes — RESOLVED by the anonymous mapper.** The shared-memory-slab
era left post-result teardown crashes (`NSHostingView` deinit, AttributeGraph
`Node::destroy`) that wrote crash reports without failing tests. Those are **gone**
with the anonymous mapper (P3.1b-iii): the contiguity removed the metadata
over-reads, and discarding deallocation actions removed the JIT'd-destructor
teardown path. The suite now runs with zero agent crash reports.

### P3.2 — Hot update via agent respawn — DONE
Edit the preview body, recompile to a new `.o`, respawn the agent, the new
render reflects the change. No in-place patching. "Respawn" at the `JITSession`
layer = destroy the old session (kills its agent) + create a new one (spawns a
fresh agent); the daemon orchestration (FileWatcher → recompile → respawn) is
P3.4.
- **Test** (`CompilerObjectTests.rerendersAfterRecompileInFreshAgent`, mirrors
  `reResolvesSymbolAfterRecompile`, **no new production code**): compile a
  render-probe source set to color A (red) via `Compiler.compileObject`, link in
  a remote session, `runOnMain` the render entry, assert the sampled pixel is
  red; then compile the **same source edited to color B** (blue), link in a
  **fresh** remote session, render, assert blue. Proves recompile → respawn →
  re-render with the real `Compiler`.
- **Confounded finding RESOLVED — the default target works.** The earlier claim
  that `Compiler.compileObject`'s default `-target arm64-apple-macosx14.0` fails
  in the JIT (minos 14 → Swift back-deployment referencing
  `___mh_executable_header`/`___dso_handle`) was an artifact of the macOS
  shared-exec outage, where every compile variant failed for the unrelated shm
  reason. Re-verified cleanly on the anonymous mapper: the default `Compiler`
  target links **and renders** in the agent. **No host-OS `target:` option was
  added** — `Compiler.compileObject` is unchanged.
- **Verify (met):** render v1 = red; recompile edited source; render v2 = blue,
  in a fresh agent. Suite 29/29, 10/10 parallel runs green, zero orphan agents,
  zero crash reports. Commit pending.

### P3.3 — Begin/End/cancelUpdate handshake (§5/§6) — CONDITIONAL
Only if no-restart with `@State` preservation later earns its keep. Bracket an
update so an in-flight render never observes a half-applied edit; cancel reverts
from the redo log. New wire verbs.
- **Verify (planned):** BeginUpdate → writes → EndUpdate → UpdateComplete drives
  a render; CancelUpdate mid-stream leaves the prior image rendering.

### P3.4 — Daemon session-lifecycle integration (pulls in SP5) — IN PROGRESS
Route structural edits from `PreviewSession`/FileWatcher to the JIT path instead
of dylib rebuild; literal-only edits stay on `DesignTimeStore`. The richer
`SessionResolver`/JIT API (Phase 1 SP5) lands here.

**Render-surface decision (agreed): agent-rendered bitmaps (model A).** The
structural path today renders **in the daemon process** (`loadPreview` dlopens
the dylib, calls `@_cdecl("createPreviewView")`, hosts the returned
`NSHostingView` in the daemon's window, snapshots via `cacheDisplay`,
HostApp.swift:80-153, :209). The JIT respawn path renders **inside the agent
process** instead, and the daemon serves `preview_snapshot` from the agent's
bitmap. Chosen over in-process JIT-in-daemon because in-process linking
reintroduces the per-edit Swift-metadata leak that respawn-first exists to avoid
(no `__swift5_proto`/`__swift5_types` deregister; Phase 1 SP0d-D). The cost of
model A is small here because **macOS is snapshot-only**: there is no macOS
touch/interaction tool to re-route (`preview_touch` is iOS-simulator-only and
already runs in its own on-device host-app process over a TCP socket via
`IOHIDEvent` injection; it is out of P3.4 scope). So only `preview_snapshot`
moves to the agent bitmap; interaction is untouched.

**New unknowns under model A (both de-riskable in the JIT module before any
`HostApp` change):**
- **U-E:** the agent must return a **variable-size bitmap** to the host, but
  `runOnMain` only returns an `Int32`. Needs a buffer-return surface (a new EPC
  byte-returning wrapper, or the agent writes the bitmap to a host-supplied path
  and the host reads the file).
- **U-F:** the agent must render the **real `Compiler` bridge** output (a
  `createPreviewView`-style entry returning a retained `NSHostingView`), not a
  self-contained `ImageRenderer` probe.

**Chunking (de-risk first):**
- **P3.4a — agent bitmap-return surface (U-E) — DONE.** File transport chosen:
  the agent renders and writes the bitmap to a host-supplied path, the host reads
  it. Needs **zero new EPC/C++ wire code** — it reuses the `runOnMain` `Int32`
  status surface and the existing bridge-source-templating pattern. Test
  `CompilerObjectTests.rendersBitmapToFileFromAgent`: template a render source
  with a unique temp PNG path, compile via `Compiler.compileObject`, link
  remotely, `runOnMain` render-and-write, host reads + decodes the PNG, center
  pixel is red. The EPC byte-return wrapper stays the fallback if file transport
  proves inadequate (it won't for snapshots). *Verify (met):* 30/30 green, 3/3
  parallel runs, zero orphans, zero crash reports. Commit pending.
- **P3.4b — real bridge renders in the agent (U-F) — DONE.** Added the render
  seam to `BridgeGenerator` (model A): `generateCombinedSource(renderOutputPath:)`
  emits a nullary `@_cdecl("renderPreviewToFile")` for macOS that builds the
  **same** `viewCode` as `createPreviewView`, rasterizes it headless via
  `ImageRenderer`, and writes a PNG to the baked path. Nullary keeps it on the
  `runOnMain` surface; the path is baked because the daemon recompiles per
  structural edit. `createPreviewView` is untouched, so the in-daemon path is
  undisturbed. Test `CompilerObjectTests.rendersRealBridgeToFileFromAgent` drives
  a real combined bridge (DesignTimeStore + `__PreviewBridge` + thunk'd user
  `#Preview`) through the agent and asserts the host-decoded PNG is green. No
  extra agent `dlopen` was needed (Observation comes in transitively via SwiftUI).
  *Verify (met):* 31/31 JIT green, 69/69 `BridgeGenerator` core green, zero
  orphan agents. Commit pending.
- **P3.4c — daemon seam (U-D).** Route structural edits to
  recompile → respawn → agent-render → serve `preview_snapshot`; literal path
  unchanged. Split:
  - **P3.4c-i — protocol seam + structural→agent snapshot.** Define a
    `StructuralReloader` protocol in `PreviewsCore` (JIT-free); `PreviewsJITLink`
    implements it; the executable composes them, injecting the real reloader only
    when `jitEnabled`. **Chosen on layering merit, not to appease CI** (base owns
    the abstraction, JIT module owns the mechanism, app wires them) — the `#if`
    alternative was rejected as the actual workaround. As a side effect the
    non-JIT build still compiles. A session's first `compile()` keeps the existing
    in-daemon dylib + `NSHostingView`; the first **structural** edit switches the
    session to agent-rendered and `preview_snapshot` serves the agent's PNG.
    Three steps:
    - **c-i-1 — protocol + `PreviewSession.compileObjectForJIT()` — DONE.** The
      protocol is `renderObject(at:entrySymbol:)`, agnostic to
      respawn-vs-capped-persistent (the impl picks). `compileObjectForJIT` emits a
      render-bridge `.o` (baked PNG path) returning a `JITRenderBuild`. *Verify
      (met):* `StructuralReloaderTests` (mock reloader) — the `.o` exports
      `_renderPreviewToFile` and the plumbing routes; 305/305 `PreviewsCore` green;
      Core stays JIT-free so the non-JIT build compiles by construction.
    - **c-i-2 — real `JITStructuralReloader` in `PreviewsJITLink` — DONE.**
      Implements the protocol over a remote `JITSession` (spawn agent →
      `addObject` → `runOnMain(entrySymbol)`, throws on non-zero status);
      respawn-per-edit via `JITSession` `deinit`. Required adding `PreviewsCore`
      as a `PreviewsJITLink` dependency (the JIT module now implements a Core
      protocol; also fixed a transitive `_SwiftSyntaxCShims` module error). Test
      `JITStructuralReloaderTests` drives a real `compileObjectForJIT` `.o` through
      the reloader and asserts the agent-written PNG is green. *Verify (met):*
      32/32 JIT green, 3/3 parallel, zero orphans, zero crash reports.
    - **c-i-3 — host wiring — DONE (pending CI non-JIT check).** (a) `PreviewHost`
      gained `structuralReloader: (any StructuralReloader)?` + an
      `agentImagePaths` map; `jitStructuralReload(sessionID:session:)` compiles the
      `.o`, calls `renderObject`, records the PNG; `watchFile`'s structural branch
      prefers it when injected, else the existing dylib path. (b)
      `MacOSPreviewHandle.snapshot` returns the agent PNG (via new
      `Snapshot.encode(imageAt:format:)`, PNG passthrough / JPEG transcode) when
      the session is agent-backed. (c) Composition root: one `#if PREVIEWSMCP_JIT`
      in `PreviewsMCPApp` injects `JITStructuralReloader()`; `Package.swift` adds
      `PreviewsJITLink` to `PreviewsCLI` and defines `PREVIEWSMCP_JIT` **only when
      `jitEnabled`**. Daemon logic stays `#if`-free (Core protocol only); the one
      conditional is at the app entry where composition belongs. *Verify (met):*
      `PreviewHostJITReloadTests` (host records the agent image; nil reloader falls
      through) + `MacOSPreviewHandleAgentSnapshotTests` (snapshot returns the agent
      PNG); macOS 3 / engine 9 / JIT 32 green; full JIT `swift build` green. The
      non-JIT build (`jitEnabled=false`) is verified by CI on push.
  - **P3.4c-ii — literal-after-structural — DONE (fallback).** Once a session is
    agent-rendered the view lives in the agent, so the in-daemon `DesignTimeStore`
    literal path can no longer update it (`applyLiteralChanges` would no-op for
    lack of a loader). `watchFile` now gates the literal fast path on
    `agentSnapshotPath(for:) == nil`, so an agent-backed session routes **any**
    edit through the structural JIT reload (re-renders in the agent). Correct but
    not the ~10ms path. The **proper** cheap path — re-seed the agent's
    `DesignTimeStore` over the wire and re-render without recompiling — is deferred
    (needs an agent setter surface). The routing lives in the `FileWatcher`
    closure (not unit-tested); covered by the deferred `examples/` E2E. *Verify
    (met):* full `swift build` green, macOS/engine/JIT suites green.
- **P3.4d — latency (U-C).** Measure structural respawn vs the <200ms target.

**Deferred infra (separate from architecture): JIT-in-CI.** CI skips the JIT
path only because the targets need `third_party/llvm-build` (multi-GB prebuilt
LLVM + orc-rt) that CI does not have; the `jitEnabled` gate makes the non-JIT
build green. Making CI **run** the JIT tests means caching or building that
artifact once and reusing it — a self-contained infra task that does **not**
shape the daemon design. Deferred (Phase 3 infra / Phase 4); tracked here. Until
then JIT tests stay local-only and the protocol seam keeps non-JIT CI green.

- **Verify (planned):** an `examples/` project: a literal edit hot-reloads via
  `DesignTimeStore` (existing path, ~10ms); a structural edit reloads via the
  JIT path (respawn), same daemon session, no daemon restart.

### P3.5 — Plan doc + PR — IN PROGRESS
This document, mirroring the Phase 1/2 plan docs, updated as work lands. PR #190
(draft), watched to green. CI does not build the JIT targets, so JIT tests are
local-only; the non-JIT build must stay green.

## Recompile-narrowing gaps (uncaptured — these gate the latency target)

P3.4 routes structural edits to the JIT respawn path, but as planned it still
recompiles the **whole module** every edit (`PreviewSession.compile()` passes the
full `buildContext.sourceFiles` to swiftc; `Compiler.swift:141`). Respawn +
JIT-link removes the full *relink*, not the full *compile*. On a 1000-file module
the compile dominates, so the design's <200ms target is unreachable until the
recompile is narrowed to the changed file. The design names the prerequisite
(`prompts/jit-executor-design.md:260`, "incremental swiftc") but neither piece
below is specified or built.

### G1 — Incremental compile (refined by W4)
**Missing.** A way to re-emit only the edited file's object. W4
(`research/scripts/analysis/w4-compile-side.md`) captured how Apple does this and
it splits by module boundary, because Swift compiles a module as a unit and a
module cannot import itself:
- **Cross-module (size-independent).** Dependency modules are built once to a
  `.swiftmodule` and consumed as prebuilt inputs (`-experimental-emit-module-
  separately`, `-I` + explicit `.swiftmodule`). An edit never re-parses them.
  This is the real "compile against a prebuilt module" shape.
- **Same module (size-dependent).** There is no prebuilt-interface trick. The
  frontend is handed the **full filelist** every edit to parse and type-check;
  `-incremental` + the `-output-file-map` then restrict the back end
  (SILgen/IRGen) to the changed file's `.o`. So per-edit cost = parse/bind all N
  files + codegen one file. Apple measured ~1.3s on 61 files; this grows with N.
  An edit to a referenced public declaration also re-emits its dependents, so the
  JIT must relink the **set** of changed objects, not always one.

`Compiler.compileObject` takes one source today and does neither: no persistent
`-incremental`/output-file-map state, no prebuilt-`.swiftmodule` inputs. Two
implementation paths were considered: (a) adopt swiftc incremental honestly
(persistent per-session build dir, full filelist, re-emit changed objects);
(b) the stable-module/editable-unit split — put the editable preview in a
**separate** module that imports the bulk as a prebuilt `.swiftmodule`.

**Verdict (W5, `research/scripts/analysis/w5-scaling.md`, CLOSED): path (b) is
mandatory.** Path (a) does not scale. Same-module incremental re-emits only 1
object but pays whole-module front-end (parse+bind all N files) every edit:
0.65 / 1.41 / 2.82 / 6.06 s at N = 100 / 250 / 500 / 1000 (~45ms + 6ms/file), so
the 200ms budget breaks at ~25 files — a conservative lower bound on trivial
bodies, real SwiftUI breaks sooner. The split holds per-edit time **flat
~0.144s** from N=100 to 1000 (bulk built once, not per edit). This is what Apple
already does (W4 thunk: one `-primary-file` against prebuilt `.swiftmodule`s).
Fan-out (W5 M2): a body edit is **1 object** regardless of dependents; an
interface edit to a decl referenced by K files is **1+K** objects — the JIT must
budget relinking that set. The auto-split mechanism is W7; W5 is its
justification.
- **Verify (met by W5; split feasibility met by W7):** the same-module-vs-split
  curves above. W7 (`research/scripts/analysis/w7-autosplit.md`, CLOSED) proves
  the split is **feasible for the common case**: an `internal` SwiftUI view
  compiles in a separate editable unit via `@testable import` against a stable
  module built `-enable-testing` (free — previews are Debug), edit→relink flat
  ~0.14s at stable N=200 and 1000. Four break-cases: (1) preview touches
  `private`/`fileprivate` bulk decls (invisible — promote to `internal` or
  co-locate); (2) `@_spi` decls (need a generated matching `@_spi` import);
  (3) editing the stable module's **own interface** (re-emits the `.swiftmodule`
  ⇒ W5 same-module cost + 1+K relink — only preview-side edits stay flat);
  (4) `package` decls (need a shared `-package-name`). Both soft spots are now
  closed by the **integrated POC — PASSED** (`cfe9bda`,
  `research/jit-poc/build-split.sh`): the full chain (split → `@testable`
  single-file compile → JIT-link → render) proven end-to-end, v1 renders red and
  edited v2 renders blue, so S2 symbol override is demonstrated, not cited.
  Numbers: edit→pixels **~233ms** with respawn semantics (compile ~165ms +
  spawn/dlopen/link/render ~69ms); a **persistent agent** re-linking each
  generation into a fresh `JITDylib` pays ~2ms after compile ⇒ **~167ms**, under
  the 200ms budget. Load-bearing implementation findings: the agent **must** call
  `LLJIT::initialize(JD)` per generation (runs `jit_dlopen`, registers
  `__swift5_*` metadata — SwiftUI conformance lookups segfault without it), and
  the ObjCSelrefPlugin + `ExecutorNativePlatform` stack is required (SwiftUI is
  selref-heavy). Break-case (1) is **impossible by construction at file
  granularity** (a moved file's `private` decls move with it; zero
  `private`/`fileprivate` decls in any preview-bearing `examples/` file) — rule:
  the executor always splits at file granularity.

### G2 — A file-identifying FileWatcher
**Missing.** `FileWatcher` signals only "something in the watched set changed",
not which file (`FileWatcher.swift`). G1 needs the changed path to pick the file
to recompile. The watch scope is already ~"project sources minus dependencies"
(deps arrive prebuilt via `-I`/`-L`), so the gap is identity, not scope.
- **Verify:** editing file X in a multi-file target delivers X's path to the
  recompile; an edit to unrelated file Y recompiles Y, not X.

### Model mismatch — RESOLVED (by W5+W7)
The design's fast path assumes edits land in the **editable/preview layer** on
top of a rarely-rebuilt **stable module**; an edit to an arbitrary stable-module
file falls to the slower path. Evidence settled the choice: target
**preview-layer edits** for the flat ~0.14s fast path (W7), and accept that
edits to the stable module's own interface fall back to W5 same-module cost
(+1+K relink) — the rare hot-path case. "Any edited file reloads sub-second" is
not achievable at scale (W5: whole-module front-end breaks 200ms at ~25 files)
and is no longer a goal.

### Apple-evidence status (W3/W4/W5 — CLOSED)
W3 verified Apple's respawn-only *dispatch* (8 edit kinds, zero `write_mem`;
`w3-empirical-capture.md`). W4 (`w4-compile-side.md`, `w4-thunk-argv.txt`) closes
the compile side: Apple recompiles **one file**, confirmed by object-mtime diff
(1 of 61) **and a live capture of the preview thunk `swift-frontend` argv** —
exactly one `-primary-file` (the edited file), `-vfsoverlay` thunk substitution,
prebuilt-module reuse via `-disable-implicit-swift-modules` +
`-explicit-swift-module-map-file` + `-I` (the G1 cross-module shape, confirmed).
W5 (`w5-scaling.md`) measured the scaling and **makes the stable-module/editable-
unit split mandatory** (numbers in G1).

**Mechanism correction (W4):** Apple does **not** use Swift dynamic replacement
for previews on Xcode 26.x — no `-enable-implicit-dynamic`, zero `__swift5_replace`
sections in thunk objects. It recompiles the edited file into a fresh
`PreviewRegistry` entry and **respawns** (PreviewRegistry-reentry, matching W3
respawn-only dispatch). This corrects the prior `project_jit_dynamic_replacement`
assumption; our respawn-first decision is unaffected (only the rationale changes).

**Bonus (W4):** Apple's literal fast-path is **data injection**
(`__designTimeString`/`Integer` + fallback), not recompilation — the same idea as
this project's `DesignTimeStore`. **W7 — CLOSED:**
auto-split is feasible for the common case (matrix + break-cases in G1).
**Integrated POC — PASSED** (`cfe9bda`): the full split → `@testable` →
JIT-link → render chain is proven; numbers and findings in G1.
**Generation-soak — DONE, decision ratified.** 500 generations, one persistent
host, fresh JD each: latency FLAT (link ~0.37-0.47ms, render ~0.33-0.43ms
medians across all windows; `swift_conformsToProtocol` does not slow), RSS
linear ~87KB/generation (unreclaimable — `__swift5_*` cannot deregister), zero
mprotect/MAP_JIT failures, zero wrong pixels. Verdict: **capped-persistent**
(see "Key decision", amended to respawn-on-cap).

**W6 — CLOSED** (`research/scripts/analysis/w6-designtime.md`). Two results.
*Canvas-is-split (refines G1):* Apple's canvas thunk compile has **no**
`-filelist`/`-incremental`/batch-mode — it is single `-primary-file` +
`-vfsoverlay` + explicit module map, i.e. **already the W5/W7 split shape**, so
the canvas latency number is the split number, not the same-module number.
*Injection lifecycle:* `#salt_n` IDs generated at thunk compile → runtime value
table keyed by ID, read via `__designTime{String,Integer,Float,Boolean}` → on a
literal edit, re-inject by ID via the `PreviewsInjection` `EntryPoint`
`UpdatePayload` stream — **no recompile, no respawn**. Structural edits take
`PerformFirstJITLink`/`JITLinkEntrypoint` instead. Our `DesignTimeStore`
(`@Observable` + `@_cdecl designTimeSet*`) is a faithful mirror. The boundary is
`LiteralDiffer` skeleton-equality, including the UIKit-region downgrade (#160).
Minor open: Apple's `UpdatePayload` wire format read from symbol names, not a
decoded live XPC dump.

**Executor edit-tier model (research arc complete — W3-W7 all CLOSED):**
1. **Literal-only SwiftUI edit** → value push by ID into the running agent
   (`DesignTimeStore` path) — no compile, no respawn. Cheapest.
2. **Structural edit** → W7 split compile (one file vs prebuilt
   `.swiftmodule`s) + JIT-link into a fresh `JITDylib` under capped-persistent
   (respawn-on-cap). ~167ms.
3. **UIKit-region literal edit** → tier 2 (UIKit captures the value once and
   never observes, #160).
Classify edits exactly as `LiteralDiffer` does (skeleton or literal-count change
⇒ tier 2; literal value change in a SwiftUI region ⇒ tier 1).

## Phase 3 status: IN PROGRESS

P3.1 + P3.2 done. The agent links a real SwiftUI preview, runs its body and
renders it to a bitmap on the agent's main thread (P3.1a/b-i/b-ii), over a
contiguous **anonymous** executor-memory slab (P3.1b-iii) that fixes U-A while
staying within macOS's executable-memory rules (the shared-memory slab was
reverted as macOS-incompatible). P3.2 proves recompile → respawn → re-render
through the real `Compiler` (default target works, no `compileObject` change).
Suite 29/29, 10/10 parallel runs green, zero crashes. Next: P3.4 (daemon
session-lifecycle integration; P3.3 stays conditional).

## Scope boundaries

- **Phase 3 (this branch):** P3.1–P3.5. Respawn-first; local unix-socket
  transport (inherited from Phase 2).
- **Deferred Phase 4+:** in-place `write_mem` fast path + the handshake (P3.3 if
  not pulled in); large-module scaling; XPC/gRPC transports; iOS device agent;
  LLVM bundling; crash recovery; multi-session.

## Immediate next step (resume pointer for a fresh session)

**State:** P3.1 + P3.2 are DONE on `main`-bound PR #190, CI green. Branch
`jit-phase3-session-integration` (baseline `a8d5909` = anonymous contiguous
mapper; P3.2 adds only a test). Working tree clean. Run JIT tests with
`swift test --filter PreviewsJITLinkTests` (builds `PreviewAgent` too); expect
29 tests green, zero orphan `PreviewAgent` processes. If `third_party/llvm-build`
is missing, run the bootstrap skill with `--jit` (do NOT rebuild LLVM if it
exists).

**Next:** P3.4 (daemon session-lifecycle integration, pulls in SP5) — route
structural edits from `PreviewSession`/FileWatcher to the JIT respawn path while
literal-only edits stay on `DesignTimeStore`. P3.3 (Begin/End/cancelUpdate
handshake) stays conditional. The respawn mechanism itself is proven by P3.2.

**Pitfalls carried forward:**
- macOS denies `mprotect`-to-exec on `MAP_SHARED` memory (no entitlement / reboot
  helps). The slab is anonymous now; never reintroduce the shared-memory mapper.
- When debugging, do NOT `pkill -9` loop hundreds of JIT agents. Use modest
  verification loops (10–15 runs). Clean session teardown reclaims memory; only
  kill stray agents at the end.
- The agent's anonymous mapper must `InvalidateInstructionCache` on exec segments
  and discards deallocation actions (process-lived image, D3). Don't re-add
  dealloc-action running.
- macOS crash reports for the agent live in `~/Library/Logs/DiagnosticReports/
  PreviewAgent-*.ips` (parseable JSON after the first line); the faulting-thread
  backtrace is the fastest way to localize an agent crash.

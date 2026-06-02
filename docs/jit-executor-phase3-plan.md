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

## Key decision (agreed): respawn-first

Updates use the **agent-respawn** model, not in-place `write_mem` patching.

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

### P3.2 — Hot update via agent respawn — TODO (resume here)
Edit the preview body, recompile to a new `.o`, respawn the agent, the new
render reflects the change. No in-place patching. "Respawn" at the `JITSession`
layer = destroy the old session (kills its agent) + create a new one (spawns a
fresh agent); the daemon orchestration (FileWatcher → recompile → respawn) is
P3.4.
- **Planned test** (in `CompilerObjectTests`, mirrors `reResolvesSymbolAfterRecompile`,
  needs no new production code): compile a render-probe-style source set to
  color A via `Compiler.compileObject`, link in a remote session, `runOnMain`
  the render entry, assert the sampled pixel is red; then compile the **same
  source edited to color B**, link in a **fresh** remote session, render, assert
  blue. Proves recompile → respawn → re-render with the real `Compiler`.
- **CAVEAT — re-verify cleanly, prior finding is confounded.** A first P3.2
  attempt concluded `Compiler.compileObject`'s default `-target
  arm64-apple-macosx14.0` produces objects that fail in the JIT (minos 14 →
  Swift back-deployment referencing `___mh_executable_header`/`___dso_handle`)
  and that the JIT path needs the **host-OS** target. **That whole diagnosis ran
  during the macOS shared-exec outage, so every compile variant failed for the
  unrelated shm reason — the target/minos/arch conclusions are unreliable.**
  Start P3.2 by re-checking, on the now-working anonymous mapper, whether the
  default `Compiler` target links in the agent at all. Only add a host-OS
  `target:` option to `Compiler.compileObject` if it genuinely fails (it may
  not). The fixtures compile with `xcrun swiftc` and no `-target` (host default),
  which is the known-good recipe.
- **Verify (planned):** render v1 = red; recompile edited source; render v2 =
  blue, in a fresh agent. (PID differs across the respawn by design.)

### P3.3 — Begin/End/cancelUpdate handshake (§5/§6) — CONDITIONAL
Only if no-restart with `@State` preservation later earns its keep. Bracket an
update so an in-flight render never observes a half-applied edit; cancel reverts
from the redo log. New wire verbs.
- **Verify (planned):** BeginUpdate → writes → EndUpdate → UpdateComplete drives
  a render; CancelUpdate mid-stream leaves the prior image rendering.

### P3.4 — Daemon session-lifecycle integration (pulls in SP5) — TODO
Route structural edits from `PreviewSession`/FileWatcher to the JIT path instead
of dylib rebuild; literal-only edits stay on `DesignTimeStore`. The richer
`SessionResolver`/JIT API (Phase 1 SP5) lands here.
- **Verify (planned):** an `examples/` project: a literal edit hot-reloads via
  `DesignTimeStore` (existing path, ~10ms); a structural edit reloads via the
  JIT path (respawn), same daemon session, no daemon restart.

### P3.5 — Plan doc + PR — IN PROGRESS
This document, mirroring the Phase 1/2 plan docs, updated as work lands. PR #190
(draft), watched to green. CI does not build the JIT targets, so JIT tests are
local-only; the non-JIT build must stay green.

## Phase 3 status: IN PROGRESS

P3.1 done. The agent links a real SwiftUI preview, runs its body and renders it
to a bitmap on the agent's main thread (P3.1a/b-i/b-ii), over a contiguous
**anonymous** executor-memory slab (P3.1b-iii) that fixes U-A while staying
within macOS's executable-memory rules (the shared-memory slab was reverted as
macOS-incompatible). Suite 28/28, 15/15 parallel runs green, zero crashes. Next:
P3.2 (hot update via agent respawn).

## Scope boundaries

- **Phase 3 (this branch):** P3.1–P3.5. Respawn-first; local unix-socket
  transport (inherited from Phase 2).
- **Deferred Phase 4+:** in-place `write_mem` fast path + the handshake (P3.3 if
  not pulled in); large-module scaling; XPC/gRPC transports; iOS device agent;
  LLVM bundling; crash recovery; multi-session.

## Immediate next step (resume pointer for a fresh session)

**State:** P3.1 is DONE and on `main`-bound PR #190, CI green. Branch
`jit-phase3-session-integration`, baseline commit **`a8d5909`** (anonymous
contiguous mapper). Working tree clean. Run JIT tests with
`swift test --filter PreviewsJITLinkTests` (builds `PreviewAgent` too); expect
28 tests green, zero orphan `PreviewAgent` processes. If `third_party/llvm-build`
is missing, run the bootstrap skill with `--jit` (do NOT rebuild LLVM if it
exists).

**Next:** P3.2 (hot update via agent respawn) — see the P3.2 subproblem above
for the test design and the **confounded-finding caveat** (re-verify whether
`Compiler.compileObject`'s default target works in the JIT before assuming it
needs a host-OS target).

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

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

#### P3.1b — render the view offscreen to a bitmap — TODO
Extend the agent to host `NSApplication` (`.accessory`) and add a main-thread
calling surface (a `RunOnMainThread`-style verb) to invoke a real
`createPreviewView`-style entry, build an `NSHostingView`, and render it
offscreen to a bitmap. Retires U-A and U-B.
- **Verify (planned):** a test compiles a SwiftUI preview whose body renders a
  known solid color to `.o`, links it in the agent, renders on the agent's main
  thread, and gets back a non-empty PNG whose pixels are the expected color.

### P3.2 — Hot update via agent respawn — TODO
Edit the preview body, recompile to a new `.o`, respawn the agent, the new
render reflects the change. No in-place patching.
- **Verify (planned):** render v1 = colorA; apply edit; respawn; render v2 =
  colorB. (PID differs across the respawn by design.)

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

P3.1a done (real SwiftUI `View` body evaluates in the agent). Next: P3.1b
(offscreen render to a bitmap).

## Scope boundaries

- **Phase 3 (this branch):** P3.1–P3.5. Respawn-first; local unix-socket
  transport (inherited from Phase 2).
- **Deferred Phase 4+:** in-place `write_mem` fast path + the handshake (P3.3 if
  not pulled in); large-module scaling; XPC/gRPC transports; iOS device agent;
  LLVM bundling; crash recovery; multi-session.

## Immediate next step

P3.1b. Stand up the agent's `NSApplication` + main-thread invoke surface and
render an `NSHostingView` offscreen to a bitmap, gated by a test that asserts
the rendered pixels match a known color.

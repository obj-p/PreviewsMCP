# JIT Executor — Phase 2 plan and state

Living plan for Phase 2, "out-of-process executor." Resume from here across
sessions. Update it as work lands. Phase 1 (issue #183) is on `main` via PR #185.

## Sources of truth

- `docs/jit-executor-phase1-plan.md` (Phase 1 landed state).
- `prompts/jit-executor-design.md` §§5, 6, 8.Phase-2 (on `previews-research`).
- Branch: `jit-phase2-remote-executor` (off `main` at `04fa860`).
- Reference agent: `third_party/llvm-project/llvm/tools/llvm-jitlink/llvm-jitlink-executor/llvm-jitlink-executor.cpp`.
- Auto-memory: `project_jit_inprocess_harness`, `project_jit_dynamic_replacement`.

## Goal

Move the executor out-of-process. Swap `SelfExecutorProcessControl` for
`SimpleRemoteEPC` over a unix-domain-socket transport, stand up a small agent
process that hosts the JIT, drive link/lookup/run across the wire. Then address
propagation / patch-point publishing per design §5 (`write_mem` into running
callers). Teardown is kill-the-agent-PID.

## The seam

Phase 1 built the swap point deliberately. `PreviewsJITLinkCxx.cpp` `makeJIT`
constructs the `LLJIT` on `SelfExecutorProcessControl::Create()`. Replacing that
one EPC with a `SimpleRemoteEPC` connected to a spawned agent is the pivot. The
agent template is `llvm-jitlink-executor.cpp` (in-tree). `libLLVM.dylib` already
exports the server symbols (`SimpleRemoteEPCServer`, `FDSimpleRemoteEPCTransport`),
so the wire path builds against the artifacts we have. No LLVM rebuild.

## Decisions

- **D-P2-1 (agreed): per-session agent.** Each `JITSession` spawns and owns its
  own agent process; teardown kills that PID. Matches design §8 Phase 2
  ("spawned at session start, killed at session end") and delivers the real
  teardown in-process Phase 1 could not have (no Swift deregister API, see
  Phase 1 SP0d-D). Because each agent is its own process, the platform-bootstrap
  process-global race that forced Phase 1's single shared `LLJIT` (SP1) goes
  away: per-session `LLJIT` + per-session agent is now both viable and clean.
  Consequence: `session_create` no longer shares one `LLJIT` via `call_once`; it
  spawns an agent, builds a `SimpleRemoteEPC`, and creates a per-session `LLJIT`.

- **D-P2-2 (agreed): transport is `filedescs=<in>,<out>` over a `socketpair`.**
  "Unix domain socket first" realized the LLVM-native way `llvm-jitlink` drives
  its executor. Host creates the socketpair, spawns the agent passing the FDs,
  connects `SimpleRemoteEPC` over its end. Lowest-risk transport.

## Assumptions

- The Phase 1 C ABI (`session_create` / `session_add_object` / `session_lookup`)
  and the `SwiftEntrySectionPlugin` survive unchanged in shape. Only the EPC
  behind the `LLJIT` changes, plus a new spawn/teardown surface.
- The orc-runtime + `ExecutorNativePlatform` bootstrap dispatches to the agent
  over the wire the same way it runs in-process (this is what `llvm-jitlink`
  does).
- Alloc actions (the plugin's Swift-registration mechanism) run executor-side,
  so they will execute in the agent and register against the agent's
  `libswiftCore`.

## Unknowns (each is a verification gate)

- **U-A:** does `EPCGenericJITLinkMemoryManager` scatter allocations past 32-bit
  reach the way Phase 1's default mapper did? The unwind-slab gotcha (Phase 1
  "Discoveries") likely recurs remotely and wants the shared-memory mapper
  service (`ExecutorSharedMemoryMapperService` on the agent +
  `SharedMemoryMapper` on the host) to reserve a contiguous slab.
- **U-B (load-bearing):** do the plugin's Swift-registration alloc-actions
  resolve against the *agent's* `libswiftCore` and execute in the agent? They
  should, but this is the central risk and the reason we defer Swift metadata to
  P2.3.
- **U-C:** does our Debug-built fork orc_rt bootstrap cleanly over the wire?
- **U-D:** does shutdown order (kill agent vs `LLJIT` destruction) leave zombies
  or hang `waitForDisconnect`? Resolved in P2.4.

## Subproblems and verification criteria

### P2.1 — agent + wire + linksCObject (the spine) — DONE
New gated `PreviewAgent` C++ executable target mirroring
`llvm-jitlink-executor.cpp` (FD transport, `SimpleExecutorMemoryManager`,
`ExecutorSharedMemoryMapperService`, default bootstrap symbols). Host-side spawn
over a socketpair (`previewsmcp_jit_remote_session_create`), the simplest object
(`answer.c`, no initializers, no platform) to isolate transport + remote alloc +
remote call.
- **Verify (met):** `linksCObjectRemotely` resolves `answer` and gets 42 through
  the spawned agent. Full suite is 15 green, in-process path untouched.

**Discoveries (not in the design doc):**
- A remote call cannot reuse the in-process `call<T>` path: the looked-up address
  lives in the agent's address space, so calling it locally would crash. We
  dispatch with `ExecutorProcessControl::runAsMain(addr, {})` (new
  `previewsmcp_jit_session_run_main`). The richer wrapper-function ABI is P2.5.
- A bare remote `LLJIT` needs four explicit settings or `create()` aborts (the
  asserts build destroys the connected EPC on any create failure, so the real
  error is masked by `~SimpleRemoteEPC "Destroyed without disconnection"`):
  1. `setPlatformSetUp(setUpInactivePlatform)` — the default platform wants the
     orc runtime we have not wired remotely yet (P2.2).
  2. `setObjectLinkingLayerCreator(ObjectLinkingLayer(ES))` — the LLJIT default
     is `RTDyldObjectLinkingLayer` + in-process `SectionMemoryManager`, wrong for
     a remote EPC. The one-arg `ObjectLinkingLayer` uses the EPC's memory manager.
  3. `setLinkProcessSymbolsByDefault(false)` — the default sets up a
     process-symbols dylib via a dylib-manager bootstrap the agent does not host.
     `answer.c` has no external symbols. Revisit when a fixture needs process
     symbols.
  4. Initialize the native target/asm printer on the remote path too (the
     in-process `makeJIT` did this in its own `call_once`; the remote path is
     separate).
- Agent location for dev/test: `JITSession.bundledAgentPath()` resolves
  `PreviewAgent` as a sibling of `Bundle.module` in the build dir. The test
  target depends on `PreviewAgent` so `swift test` builds it first.

### P2.2 — platform + orc_rt over the wire — DONE
Swapped the remote path from the inactive platform to
`ExecutorNativePlatform(orc_rt_path)`. The agent gained `SimpleExecutorDylibManager`
so process-symbol lookup works over the wire, and `run_main` now `initialize()`s
the session (runs constructors in the agent via the platform). The remote create
takes `orc_rt_path`; the Swift remote init resolves it from `Bundle.module` like
the in-process init.
- **Verify (met):** `runsObjectInitializerRemotely` (`ctor.c`, constructor runs
  in the agent) and `resolvesThreadLocalStorageRemotely` (`tlv.c`) both return
  through the agent. 17 tests green.
- **U-C resolved:** the orc runtime bootstraps cleanly over the wire.
- **U-A did NOT bite for C:** the default remote memory manager
  (`EPCGenericJITLinkMemoryManager`) handled `ctor.c`/`tlv.c` without the unwind
  32-bit slab. NOT adding the shared-memory slab speculatively. Revisit only if a
  Swift object trips it in P2.3.

### P2.3 — Swift metadata across the wire — DONE
Added `SwiftEntrySectionPlugin` to the remote layer and resolved U-B. The full
suite now has remote variants of all six POC scenarios plus plain Swift; 24
tests green in parallel, zero orphan agents.

**Discoveries (U-B and the agent's Swift runtime):**
- The agent is a C++ binary with no Swift link, so Swift objects fail to
  materialize with "Symbols not found" until the agent loads the runtime. Fix:
  the agent `dlopen`s `libswiftCore`, `libswift_Concurrency`, `libswiftFoundation`,
  `libswiftDispatch` (RTLD_GLOBAL) at startup; the process-symbol generator then
  resolves against them. They live in the dyld shared cache (so `ls` shows
  nothing) but `dlopen` of the install path works. Real previews will pull SwiftUI
  the same way in Phase 3.
- **U-B (the load-bearing risk):** the plugin recorded `ExecutorAddr::fromPtr(Fn)`,
  the HOST address of its registration shims. In-process that works (host ==
  executor); remotely the alloc action runs in the agent and jumps to a garbage
  address (crashed with an Instruction Abort in `SimpleExecutorMemoryManager::finalize`
  running the alloc action, PC in libLLVM `__LINKEDIT`). Fix: the registration
  SPS shims now live in the AGENT (calling its own `swift_register*` via `dlsym`),
  advertised as EPC bootstrap symbols; the host reads their agent addresses with
  `getBootstrapSymbols` and constructs the plugin with them. `SwiftEntrySectionPlugin`
  is now address-parameterized; in-process uses a `::inProcess()` factory that
  passes the host shim addresses. Each executor hosts its own shim.
- **U-A closed (no slab needed):** the default remote memory manager
  (`EPCGenericJITLinkMemoryManager`) handled every scenario including Swift
  conformance, async, and objc, so the unwind 32-bit slab never bit remotely. The
  shared-memory slab mapper is NOT needed. Revisit only if a future large object
  trips it.

### P2.4 — teardown = kill the agent PID — DONE (pulled forward from P2.2)
Pulled forward because the parallel test runner hung: spawned agents had no
teardown, so leaked agents held the test process's inherited stdout/stderr pipe
open and `swift-test` never saw EOF. `previewsmcp_jit_session_destroy` resets the
owned `LLJIT` (which calls `ES.endSession()` → `EPC->disconnect()`, line 1633 of
Core.cpp, closing the wire so the agent's `waitForDisconnect` returns), then
`kill(SIGKILL)` + `waitpid` the agent PID as the design's backstop. In-process
sessions just free the handle (the shared `LLJIT` stays, D3). Wired to a Swift
`deinit`.
- **Verify (met):** parallel `swift test --filter PreviewsJITLinkTests` passes
  17/17 in 0.18s with zero leftover `PreviewAgent` processes. U-D resolved.

### P2.5 — address propagation / patch-point publishing (design §5) — DONE
Exposed the `write_mem` patch primitive over the wire:
`previewsmcp_jit_session_write_pointer` → Swift `writePointer(at:value:)` →
`getMemoryAccess().writePointers`. SimpleRemoteEPC has no default memory access
(`createDefaultMemoryAccess` returns nullptr), and the orc-runtime write wrappers
are not available at EPC-setup time, so the agent hosts its own SPS
`write_pointers` wrapper (advertised as the `__previewsmcp_write_pointers`
bootstrap symbol), and the host's `Setup.CreateMemoryAccess` builds an
`EPCGenericMemoryAccess` with `FuncAddrs.WritePointers` from it.
- **Verify (met):** `publishesNewAddressIntoSlotRemotely` (`patch_slot.c`): a
  function-pointer slot starts dispatching to v1 (returns 1); the host writes the
  agent address of `impl_v2` into the slot via `writePointer`; the next dispatch
  returns 2. The write is pointer-width aligned, so atomic against an in-flight
  read per design §5 point 1. 25 tests green in parallel, zero orphan agents.
- **Not in scope (Phase 3):** the Begin/End/`cancelUpdate` update handshake
  (§5/§6) and wiring patch-points to SwiftUI witness/vtable slots on real edits.
  This chunk proves the publish mechanism, not the edit-driven planner.

## Phase 2 status: COMPLETE (local unix-socket transport)

The executor is out-of-process end to end. All six POC scenarios link, register
Swift metadata, and run inside a spawned agent over a SimpleRemoteEPC socket;
sessions tear down by killing the agent PID; and a new address publishes into a
running slot via `write_mem`. 25 tests green in parallel. Deferred to Phase 3:
SwiftUI session-lifecycle integration, the update handshake, XPC/gRPC transports,
the sidecar symbol-discovery format, iOS device agent, and LLVM bundling (U3).

## Scope boundaries

- **Phase 2 (this branch):** P2.1–P2.5. Local unix-socket transport only.
- **Deferred Phase 3+:** SwiftUI session-lifecycle integration; XPC / gRPC
  transports; sidecar symbol-discovery format (§3); iOS device agent; LLVM
  bundling for distribution (U3).

## Immediate next step

Phase 2 is merged to `main` via PR #186 (squash `ef3fa61`). The next work is
Phase 3: wire the JIT executor into the daemon session lifecycle
(`SessionResolver` + `FileWatcher` + `Compiler`), routing structural edits to
JIT-link, and add the Begin/End/`cancelUpdate` update handshake (design §5/§6).
See `prompts/jit-executor-design.md` Phase 3 on `previews-research`.

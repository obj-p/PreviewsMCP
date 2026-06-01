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

### P2.1 — agent + wire + linksCObject (the spine)
New gated `PreviewAgent` C++ executable target mirroring
`llvm-jitlink-executor.cpp` (FD transport, `SimpleExecutorMemoryManager`,
`ExecutorSharedMemoryMapperService`, default bootstrap symbols). Host-side spawn
over a socketpair, swap `SimpleRemoteEPC` into `makeJIT`. Start with the simplest
object (`answer.c`, no initializers, no platform) to isolate transport + remote
alloc + remote call.
- **Verify:** a C symbol resolves and returns 42 through the agent process
  (`linksCObject`-equivalent). Agent is a separate PID, confirmed.

### P2.2 — platform + orc_rt + remote slab over the wire
Bring up `ExecutorNativePlatform` remotely (U-C) and solve U-A with the
shared-memory mapper slab.
- **Verify:** the C initializer / TLV scenarios (`ctor.c`, `tlv.c`,
  `runsObjectInitializer`, `resolvesThreadLocalStorage`) pass remotely.

### P2.3 — Swift metadata across the wire
Confirm U-B; port the full suite onto the remote executor.
- **Verify:** all six POC scenarios (witness, conformance, swift_once, objc
  selref, objc class, async) green through the agent. The 14-test suite passes
  with the remote executor.

### P2.4 — teardown = kill the agent PID
Session/agent lifecycle ownership; `session_destroy` kills the agent and tears
down the `LLJIT`/EPC in the right order (U-D).
- **Verify:** disposing a session kills the agent, no zombie, no hang; a second
  session in the same test run is unaffected.

### P2.5 — address propagation / patch-point publishing (design §5)
`write_mem` into running callers; the `cancelUpdate`/Begin/End update handshake
(design §5, §6). Largest chunk, last. Scope sharpened once P2.1–P2.4 land.
- **Verify:** TBD (re-resolve a symbol, publish the new address into a slot a
  running caller reads, observe the new value without respawn).

## Scope boundaries

- **Phase 2 (this branch):** P2.1–P2.5. Local unix-socket transport only.
- **Deferred Phase 3+:** SwiftUI session-lifecycle integration; XPC / gRPC
  transports; sidecar symbol-discovery format (§3); iOS device agent; LLVM
  bundling for distribution (U3).

## Immediate next step

P2.1. First TDD step: a failing test that links `answer.c` through a spawned
agent and asserts the call returns 42, then the minimal agent + host spawn to
make it pass. Pause for review before moving to P2.2.

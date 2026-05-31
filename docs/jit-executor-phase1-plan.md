# JIT Executor — Phase 1 plan and state

Living plan for issue #183, "Implement custom JIT executor (Phase 1: host-side
LLVM ORC harness)." Resume from here across sessions. Update it as work lands.

## Sources of truth

- Issue #183 (acceptance criteria).
- `prompts/jit-executor-design.md` §§3, 4, 8.1 (on `previews-research`).
- `prompts/jit-executor-impl-phase1.md` (seed prompt, on `previews-research`).
- W2 POC `research/jit-poc/` (on `previews-research`), six green scenarios.
- Branch: `183-jit-executor`. Compiler driver: `Sources/PreviewsCore/Compiler.swift`.

## What is built (commits cf12422..064a26c)

- Targets `PreviewsJITLinkCxx` (C++ shim, C ABI over brew LLVM 22) and
  `PreviewsJITLink` (Swift wrapper).
- `linkAndCall(objectPaths:symbol:) -> T: FixedWidthInteger`: links one or many
  `.o` into one LLJIT, runs initializers, resolves the symbol, calls it.
- LLJIT built on an explicit `SelfExecutorProcessControl`, an
  `ExecutorNativePlatform(liborc_rt_osx.a)`, and a slab `MapperJITLinkMemoryManager`.
- Unified error-string channel marshalled to Swift `throws`.
- Tests: C and Swift smoke, process-symbol resolution, missing-symbol failure,
  initializer probe.

## Discoveries to preserve (not in the design doc)

- Running load-time initializers requires the native MachO platform set up with
  the orc runtime. A bare `LLJIT` plus `initialize()` does nothing.
- Unwind/EH needs a slab-reserving memory manager. The default per-allocation
  mmap scatters code and `__unwind_info` past 4GB under ASLR and trips a 32-bit
  delta error. This gotcha is absent from the design's §5 list.
- The JIT calling surface is integer/pointer only, because we only call our own
  thunk and edited methods are redirected by the runtime via dynamic
  replacement. See memory `project_jit_dynamic_replacement`.

## Assumptions

- We build on public LLVM ORC + JITLink, not Apple's runtime (verdict #1).
- Phase 1 validates the JIT-link plus re-resolution mechanism in-process only.
  Propagating new addresses into running callers is Phase 2+.
- The full `MachOPlatform` (via `ExecutorNativePlatform`) performs the ObjC and
  Swift runtime registration that the POC hand-rolled with plugins.

### LLVM source decision (resolves U3, was: brew scaffolding)

Build LLVM from source from `swiftlang/llvm-project` at the tag matching the
installed Swift (`swift-6.2.3-RELEASE`), not vanilla brew LLVM 22. Rationale:
the Swift runtime in-process (`libswiftCore`) is built from this fork, and the
SP1 conformance segfault is most plausibly a registration-mechanism skew between
brew LLVM 22's ORC `MachOPlatform` and that older runtime. The fork has full ORC
+ JITLink (46 headers) and `compiler-rt/lib/orc` (builds `liborc_rt_osx.a`).
Note `swift-llvm-bindings` is NOT the vehicle: it is a Swift-API binding layer
that itself needs a local LLVM checkout. We link the C++ libraries directly.
Known API skew vs brew 22: `SelfExecutorProcessControl` lives in
`ExecutorProcessControl.h` here, not its own header.

## Unknowns

- **U1 (load-bearing):** Does `MachOPlatform` + orc runtime fully subsume the
  three prescribed plugins for all six scenarios, or does some scenario still
  need a custom plugin? Resolve empirically by running the six scenarios.
  - **Partial answer (SP1, witness scenario):** No, not for Swift protocol
    conformance. A JIT-linked object with a `protocol` + conformance + an
    `any`-existential call segfaults. The crash is in the Swift runtime, in
    `swift_conformsToProtocol` → `swift_getTypeByMangledName`, triggered by an
    *unrelated* later lookup (Swift Testing's own). So our JIT'd `__swift5_proto`
    / `__swift5_types` records register but are malformed and poison the
    process-global conformance registry. The platform handles initializers and
    `swift_once` fine, but not conformance/type metadata. This is the gap the
    design's `SwiftEntrySectionPlugin` targets. Test `dispatchesThroughWitnessTable`
    is `.disabled` because the segfault takes down the whole runner.
  - **Sharpened by two diagnostic probes:** the fault is narrow.
    - Type metadata is fine: `String(describing: Box.self)` on a JIT'd struct
      (no protocol) passes, so `__swift5_types` registration and demangling work.
    - It is conformance-record registration specifically, and it happens at
      *link time*, not at the call: an object whose called function never touches
      its protocol still poisons the registry merely by being linked (its
      `__swift5_proto` record registers). So the broken thing is exactly the
      JIT-linked protocol-conformance records, not the existential dispatch.
    - **Open root-cause question:** are the conformance records mis-relocated
      (relative pointers wrong), double-registered (platform + something), or
      registered in a form the runtime mis-walks? Decides whether the fix is a
      relocation fix, suppressing the platform's auto-registration, or the plugin.
- **U2:** Does the Swift calling convention hold when we call a real `View` body
  thunk, versus the trivial nullary functions tested so far?
- **U3:** LLVM integration strategy for shipping (vendor xcframework vs CMake
  bridge vs SwiftPM binary target). Phase 1 defers, but it gates Phase 2 hardening.

## Alternatives — the central decision (U1)

The design §4 prescribes porting three hand-rolled JITLink plugins
(`ObjCSelrefPlugin`, `ObjCClassPlugin`, `SwiftEntrySectionPlugin`) because the
POC ran a bare `ObjectLinkingLayer` with no platform.

- **A. Platform-first (current path).** Use `ExecutorNativePlatform` + orc
  runtime so the real `MachOPlatform` does selref/class/metadata registration and
  initializers. Port a custom plugin only for a scenario the platform misses.
- **B. Plugins-first (design as written).** Bare `ObjectLinkingLayer`, port all
  three plugins verbatim from the POC.

Lean A: less hand-rolled code, mirrors how the runtime actually works, already
runs initializers. Treat the six scenarios as the test that decides whether A is
sufficient. This is a legitimate Phase-1 discovery, exactly what the seed prompt
says to expect.

## Subproblems and verification criteria

### SP0 — Build LLVM from the Swift fork and repoint the C++ target (prerequisite)
Build `swiftlang/llvm-project` @ `swift-6.2.3-RELEASE` (matches installed Swift)
with `compiler-rt` for the orc runtime, AArch64 + X86 targets (X86 for the
simulator later). Repoint `PreviewsJITLinkCxx` include/lib paths and
`kOrcRuntimePath` at the build output; fix the `SelfExecutorProcessControl`
include (now in `ExecutorProcessControl.h`).
- **Verify:** the existing 8 tests still pass against the fork build, and the
  `dispatchesThroughWitnessTable` scenario, re-enabled, no longer segfaults. If
  it passes, the conformance bug was the LLVM/runtime skew and SP0 also resolves
  U1 for Swift metadata. If it still crashes, the fix is a real plugin/relocation
  problem, not version skew.

### SP1 — Port the six POC scenarios as tests (acceptance core)
Translate `research/jit-poc/swift/*.swift` (greet/witness, tlv, swift_once,
objc selref, objc class, async) into `PreviewsJITLinkTests` fixtures.
- **Verify:** each scenario links and its symbol returns the expected value,
  in-process, under path A. Any scenario that fails under A names the specific
  plugin to port (resolves U1).

### SP2 — Wire `Compiler.swift` for `.o` production
Replace the test-only `swiftc` shell-out with `Sources/PreviewsCore/Compiler.swift`
for producing objects from a Swift source + target View symbol.
- **Verify:** a test compiles a source via `Compiler.swift`, links it, and calls
  the View symbol, with no direct `swiftc` invocation in the path.

### SP3 — Re-resolution on source change
Recompile a changed source, add the new `.o` to the JIT, re-resolve the symbol.
- **Verify:** the re-resolved symbol points at the new object and calling it
  returns the new behavior. (Phase 1 stops here; address propagation is Phase 2+.)

### SP4 — Custom plugin(s) only if SP1 demands
If a scenario fails under path A, port the matching plugin
(`LinkGraphLinkingLayer::Plugin`, `PostPrunePasses`, canonical `__SEG,__sect`
names, graceful early-out, no-op `notifyFailed`/`notifyRemovingResources`/
`notifyTransferringResources`).
- **Verify:** the previously failing scenario passes with the plugin added.

### SP5 — Swift API surface + SessionResolver (lighter weight, can trail)
Grow `JITLinkError` toward the design's `JITLinkSession`/`JITLinkResult`/`Symbol`
and add a `jit-linked` session kind to `SessionResolver`.
- **Verify:** `SessionResolver` can hand a session to the JIT path and back.

## Scope boundaries

- **Phase 1 (this branch):** SP1–SP5 in-process inside the test runner / daemon.
- **Deferred Phase 2+:** out-of-process agent + `SimpleRemoteEPC`; the sidecar
  symbol-discovery format (§3); patch-point publishing / `write_mem`; LLVM
  bundling; iOS device support; in-place patching.

## Immediate next step

SP1. Start with the witness/greet scenario from the POC, confirm it passes under
path A, and let the six scenarios decide U1.

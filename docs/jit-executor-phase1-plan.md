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

Original rationale (now contested, see counter-evidence): the Swift runtime
in-process (`libswiftCore`) is built from `swiftlang/llvm-project` at
`swift-6.2.3-RELEASE`, so building our LLVM from that fork might fix the SP1
conformance segfault by matching the runtime. The fork has full ORC + JITLink
(46 headers) and `compiler-rt/lib/orc` (builds `liborc_rt_osx.a`).
`swift-llvm-bindings` is NOT the vehicle: it is a Swift-API binding layer that
itself needs a local LLVM checkout; we link the C++ libraries directly. Known
API skew vs brew 22: `SelfExecutorProcessControl` lives in
`ExecutorProcessControl.h` in the fork, not its own header.

**Counter-evidence (subagent review, do not skip):** building the fork's
`libLLVM` is unlikely on its own to fix the conformance segfault. A diff of
`MachOPlatform`'s Swift-section registration between the fork at
`swift-6.2.3-RELEASE` and vanilla `llvmorg-22.1.5` found it **byte-for-byte
identical** (same `__swift5_proto` handling, same synthetic
`__llvm_jitlink_ObjCRuntimeRegistrationObject` + `RegisterObjCRuntimeObject`
bootstrap). The real runtime coupling lives in **`orc_rt`**
(`compiler-rt/lib/orc/macho_platform.cpp`), which calls private dyld/objc entry
points (`_objc_map_images`, `_objc_load_image`) that drive `libswiftCore`'s
conformance registration; and in **JITLink relocation correctness** of the
`__swift5_proto` block (bad relative pointers or >±2GB reach would make
`swift_conformsToProtocol` walk garbage and crash regardless of which LLVM we
build). So the only thing a rebuild meaningfully changes is a fork-matched
`liborc_rt`, not the LLVM libraries.

Also confirmed by the review: **no prebuilt Swift-fork LLVM with linkable C++
ORC/JITLink exists.** swift.org toolchains and Xcode's toolchain ship llvm
*tools* but no `ExecutionEngine/Orc` headers and no `liborc_rt*.a`. The iOS/sim
SDK `libLLVM.dylib` is Apple's Metal shader-compiler LLVM (C API only, zero
`llvm::orc::`/`llvm::jitlink::` symbols). If we ever do build, building from
source is unavoidable.

**Revised next step:** diagnose cheaply before any LLVM build. Turn on
`ORC_RT_DEBUG`, and inspect whether `witness.o`'s `__swift5_proto` block is
correctly relocated (dump section + relocations, check relative-pointer reach,
same class as the unwind slab issue). Treat `orc_rt` as the lever, not
`libLLVM`.

**Vendoring decision (when/if we do build):** pinned-clone script, NOT a git
submodule (mirrors how `swiftlang/swift` pulls llvm-project via
`update-checkout`, not submodules). Pin a full commit SHA, `git clone --depth 1
--filter=blob:none` + `git sparse-checkout` over
`llvm/ compiler-rt/ cmake/ third-party/ runtimes/`, into a gitignored,
SHA-keyed out-of-tree cache (not in-tree). Build Release `libLLVM` dylib +
orc_rt only into `.llvm-build/`. Gate behind an opt-in `bootstrap --jit` so
non-JIT contributors pay nothing. Scoped build est. ~8-15GB, ~20-45min on a
fast Apple Silicon. Keep `LLVM_ENABLE_RUNTIMES` empty and build compiler-rt
standalone to avoid pulling in libcxx/libunwind.

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

### SP0a — Diagnose the conformance crash cheaply (do this BEFORE any LLVM build)
The subagent counter-evidence says a fork rebuild likely won't fix it (platform
registration code is identical fork vs vanilla). So diagnose first:
- Dump `witness.o`'s `__swift5_proto` section + relocations
  (`llvm-objdump`/`otool`), reason about relative-pointer correctness and ±2GB
  reach after JIT placement (same class as the unwind slab issue).
- Run with `ORC_RT_DEBUG` to watch the orc_rt registration hand-off
  (`_objc_map_images` / `_objc_load_image`).
- **Verify:** we can name the actual cause, JITLink relocation of `__swift5_proto`
  vs an `orc_rt`↔dyld/objc contract mismatch. That decides whether the fix is a
  relocation/plugin change (no build) or specifically a fork-matched `liborc_rt`.

### SP0b — Build LLVM from the Swift fork (ONLY if SP0a points to orc_rt)
Contingent on SP0a. If the cause is the `orc_rt`↔runtime contract, the lever is
a fork-matched `liborc_rt`, possibly not a full `libLLVM` rebuild. Build per the
vendoring decision above (pinned-clone script, sparse, out-of-tree cache). Fix
the `SelfExecutorProcessControl` include (now in `ExecutorProcessControl.h`).
- **Verify:** re-enabled `dispatchesThroughWitnessTable` no longer segfaults and
  the existing tests still pass.

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

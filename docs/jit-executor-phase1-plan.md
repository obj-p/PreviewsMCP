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

- **U1 (load-bearing, RESOLVED):** Does `MachOPlatform` + orc runtime subsume the
  prescribed plugins? **Yes.** SP1 ran all six scenarios under path A and they
  pass. The only custom plugin needed is `SwiftEntrySectionPlugin` for Swift
  conformance/type metadata. The objc selref and class plugins the POC needed on
  its bare layer are unnecessary under the full platform. History below.
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
- **Findings so far (points at orc_rt section-range registration, not relocs):**
  - Static: `witness.o`'s `__swift5_proto` record uses a normal
    `ARM64_RELOC_SUBTRACTOR` + `ARM64_RELOC_UNSIGNED` 32-bit intra-object delta.
    Not exotic, not out of range. So a gross per-record relocation bug is unlikely.
  - Dynamic: the crash is `EXC_BAD_ACCESS` reading `0x3000580e8`, which the crash
    report says is "not in any region, 360681 bytes after previous region." The
    conformance-registry walk ran ~360KB **off the end of a mapped region** into
    unmapped space. Consistent with a wrongly-sized/based registered section
    range (orc_rt registration contract), not a bad relative pointer in a record.
  - `ORC_RT_DEBUG` is a no-op with brew's release `orc_rt` (logging compiled
    out). Deeper tracing of the registered range needs either lldb (no build) or
    a debug/asserts `orc_rt` (build).

### SP0b — Build LLVM from the Swift fork (DONE; result: did NOT fix it)
Built `swiftlang/llvm-project` @ `swift-6.2.3-RELEASE` via
`scripts/build-jit-llvm.sh` (pinned-clone, shallow+sparse+partial, two-phase:
libLLVM dylib with asserts, then standalone compiler-rt orc runtime).
Repointed `PreviewsJITLinkCxx` (`Package.swift` computes paths from the package
dir; orc path injected via `-DPREVIEWSMCP_ORC_RT_PATH`; `SelfExecutorProcessControl`
include → `ExecutorProcessControl.h`; `slabLinkingLayer` gained the
`const Triple&` param the older `ObjectLinkingLayerCreator` requires).
- **Result:** the fork LLVM is **19.1.5** (Swift 6.2.3's exact base; brew was
  22.1.5). The 8 non-witness tests pass on it. **`dispatchesThroughWitnessTable`
  still segfaults.** So the version-skew theory is **dead** — matching the
  runtime's exact LLVM did not fix it. The subagent was right.
- **What the debug orc_rt trace showed** (`ORC_RT_DEBUG=1`, needs a Debug-built
  orc_rt, NDEBUG gates the logging): metadata registration **succeeds**
  (`Registering object sections for 0x11fe4c000` → `Registering Objective-C /
  Swift metadata`). The crash is in the **content**: `swift_conformsToProtocol`
  follows a relative pointer in the registered `__swift5_proto` record to a wild
  address `0x3000580e8` (consistent `0x580e8` = 360681 low offset across runs),
  ~12GB away from the JIT'd image at `0x11fe4c000`. So the real bug is **JITLink
  relocation/layout of Swift conformance metadata**, version-independent.
- **Keep the fork build anyway:** it gives asserts (JITLink diagnostics), a
  Debug orc_rt (logging), and ios/iossim orc runtimes for the Phase 2 simulator
  work. The brew dependency is gone.

### SP0c — Root-cause the conformance crash (DONE; it's a section-address mismatch)
Enabled JITLink logging (env `PREVIEWSMCP_JIT_DEBUG=1`, works on the asserts
fork build) and a Debug orc_rt (`ORC_RT_DEBUG=1`). Findings:
- The conformance record's relative pointers are **correct**. JITLink emits
  `edge@0x260: Delta32 -> ...DefaultValuedVAA0C0AAMc` (the conformance
  descriptor) and the descriptor's own `Delta32` edges to protocol/type/witness,
  all small intra-image deltas. Not a relocation bug.
- JITLink places the `__swift5_proto` block at `0x124e580e8`. The crash reads
  `0x3000580e8` — **same low offset `0x580e8`, different base**. So the runtime
  accesses the section at a `0x300000000`-region address that is **not mapped**,
  while the linked address is `0x124e...`. A base / address-space mismatch in how
  the section is registered with the runtime, not the record content.
- **Not the slab:** removing the slab linking layer still crashes (different
  memory manager, same class of crash). **Not LLVM version** (SP0b). **Not
  relocs** (above).
- Conclusion: `ExecutorNativePlatform`'s automatic Swift-section registration
  hands the runtime an address the in-process executor doesn't back. This is
  exactly the gap the design's **`SwiftEntrySectionPlugin`** fills: at
  link-finalize, walk the new image's `__swift5_*` sections and register them
  with the Swift runtime using the **correct JIT-final addresses**.

### SP0d — SwiftEntrySectionPlugin + session lifetime (DONE)
Per design §4. A `ObjectLinkingLayer::Plugin` (`SwiftEntrySectionPlugin`) that, in
`PrePrunePasses`, moves `__swift5_proto` / `__swift5_types` into private sections
so the platform's wrong-address registration path skips them, keeping the blocks
live with anonymous symbols so pruning does not drop the conformance records.
Then in `PostFixupPasses` it registers each section at its final JIT address via
`swift_registerProtocolConformances` / `swift_registerTypeMetadataRecords` through
alloc actions. Built with `-fno-rtti` to match LLVM (the derived plugin otherwise
needs the base class typeinfo, which LLVM does not export).

**What landed and is verified:** suppression plus correct re-registration plus
session lifetime. `dispatchesThroughWitnessTable` passes via the
statically-emitted witness table, and `resolvesConformanceThroughRuntimeRegistry`
forces a real global-registry lookup through a dynamic cast and also passes, both
driven through a `JITSession` that owns the image. Committed as `cd4e54f`.

**Root cause found, this is the real blocker:** the re-registration itself is an
ownership bug, not an address bug. A new test `resolvesConformanceThroughRuntimeRegistry`
forces a runtime conformance lookup via a dynamic cast, which is the lookup the
witness test never exercised. With registration on it segfaults. Same-process
diagnostics proved the registered record address is correct (e.g.
`0x300054124`) but unmapped at fault time. `linkAndCall` is spike code that links,
calls, then destroys a per-call `LLJIT`, freeing the slab. The records were
registered into the process-global Swift conformance registry, which is then left
holding a dangling pointer. Confirmed by keeping the `LLJIT` alive (the dynamic
cast then returns the correct value).

**How Xcode Previews avoids this:** its agent is long-lived and `XOJITExecutor`
holds the image as a `JITDylibHandle` session (see
`research/scripts/analysis/q6-jit-runtime-findings.md`). The pseudodylib stays
resident for the whole preview, edits arrive via dynamic replacement, the image
memory and the global registry share one lifetime. There is no fire-and-forget.

**Decision (agreed): rearchitect around a session, drop `linkAndCall`.** The
session owns the image and its lifetime equals the image lifetime. Name to match
the design's `JITLinkSession` / `SessionResolver` (SP5).
- **SP0d-A:** `JITSession` C++ type + handle ABI (`session_create`,
  `session_add_object`, `session_lookup`). Verify: resolves and calls a symbol through a handle.
- **SP0d-B:** Swift `JITSession` class owning the handle,
  `lookup` returns an address, typed `call<T>` helper. Verify:
  `dispatchesThroughWitnessTable` returns 7 and `resolvesConformanceThroughRuntimeRegistry`
  returns 9 while the test holds the session, no leak hack.
- **SP0d-C:** port the existing 8 tests onto sessions, delete `linkAndCall` and
  the spike entry points. Verify: all prior tests stay green, no fire-and-forget path left.
- **SP0d-D (resolved):** there is no in-process teardown, by design. A dlsym probe
  of the in-process `libswiftCore` (Xcode 26.2) confirmed **no public
  `swift_unregister*` / `swift_deregister*` exists**, only the register entry
  points. So once `__swift5_proto` / `__swift5_types` records are registered at
  JIT addresses, that memory can never be safely freed while the process runs.
  Apple unloads only because its pseudodylib is a real dyld image whose
  image-remove hook drives the cleanup, a private dyld API we do not have.
  Decision **D3:** a `JITSession` owns an image that lives until process exit,
  there is no `session_destroy` and no `deinit` free. This is consistent and
  honest, the same lifetime the Previews agent uses. The leak is the runtime
  constraint surfaced, not a shortcut.
  - **Phase 2 teardown (investigated):** kill the agent process. A subagent
    confirmed the Swift runtime has no remove-image hook and no deregister on any
    branch (`ProtocolConformance.cpp`, `ImageInspectionMachO.cpp`), registration
    is one-way by design. dyld's pseudodylib unload (`_dyld_pseudodylib_deregister`,
    private SPI) runs deinitializers but does not make the runtime forget the
    records, and orc_rt's `macho_platform.cpp` has TODOs that a Swift/ObjC image
    is meant to be permanent and non-dlclose-able. Apple's own `XOJITExecutor`
    does not unload in-process, it respawns the agent on every edit
    (`research/scripts/analysis/w3-empirical-capture.md`), so teardown is process
    death. Phase 2 should adopt the out-of-process agent and treat one agent's JIT
    memory as non-reclaimable mid-life, bounding it by PID lifetime instead. A
    future Swift deregister API is not on the critical path.

### SP1 — Port the six POC scenarios as tests (acceptance core, DONE)
All six POC scenarios are session-driven tests and **all pass under path A**:
greet/witness conformance (SP0d), real Mach-O TLV (`tlv.c`, C `_Thread_local`),
swift_once (`swift_once.swift`, lazy global), ObjC selref (`objc_selref.swift`),
ObjC class (`objc_class.swift`, a JIT-defined `NSObject` subclass instantiated
and messaged), and async (`async_value.swift`, a suspending `Task` driven to
completion). 12 tests, stable across repeated parallel runs.
- **Resolves U1: path A is sufficient, no hand-rolled plugins needed.** The POC
  needed `ObjCSelrefPlugin` and a planned `ObjCClassPlugin` only because it ran a
  bare `ObjectLinkingLayer`. Under the full `MachOPlatform` the objc-image-load
  path (`_objc_map_images` / `_objc_load_image`) uniques selectors and registers
  classes. Our only custom plugin is `SwiftEntrySectionPlugin` for Swift
  conformance and type metadata, which the platform mis-registers. So **SP4 is
  not required**.
- **Architecture fix surfaced by the probe:** a per-session `LLJIT` does not
  work. Each `ExecutorNativePlatform` bootstrap registers process-global state
  (`findDynamicUnwindSections`), so concurrent sessions under the parallel test
  runner raced and the second failed to materialize
  `__orc_rt_macho_complete_bootstrap`. Fixed by one process-shared `LLJIT` built
  behind `std::call_once`, with each session a `JITDylib` created via
  `LLJIT::createJITDylib` (which runs platform setup so the dylib resolves
  process and stdlib symbols). This also matches D3, the shared JIT is
  process-lived.

### SP2 — Wire `Compiler.swift` for `.o` production (DONE)
Added `Compiler.compileObject(source:moduleName:extraFlags:) -> URL`, a sibling to
`compileCombined` that emits a `.o` via `-emit-object -parse-as-library` with no
link and no codesign. A `CompilerObjectTests` integration test compiles a source
through `Compiler.swift`, links the object with a `JITSession`, and calls the
symbol, no direct `swiftc` in that path. The test target gained a `PreviewsCore`
dependency. The six scenario fixtures stay on `FixtureSupport` (fast, cached).
- **Verify (met):** `compilesAndLinksObjectViaCompiler` returns 42. 13 tests green.

### SP3 — Re-resolution on source change (DONE)
ORC will not redefine a symbol inside one `JITDylib`, and a session is one
`JITDylib`, so re-resolution is a fresh `JITSession` per recompile. The
`reResolvesSymbolAfterRecompile` test compiles two versions of one `@_cdecl`
symbol (42, then 43) via `Compiler.compileObject`, links each in its own session,
and confirms v1 resolves to addr1 returning 42, v2 to a different addr2 returning
43, with no duplicate-definition error. No production code, the existing
`address(of:)` and `call` cover it.
- **Verify (met):** values 42 vs 43, addresses differ. Phase 1 stops here,
  propagating the new address into a running caller is Phase 2.

### SP4 — Custom plugin(s) only if SP1 demands (NOT NEEDED)
SP1 passed all six scenarios under path A, so no objc selref/class plugin is
required. The only custom plugin is `SwiftEntrySectionPlugin` (SP0d). Revisit
only if a future scenario surfaces a gap.

### SP5 — Swift API surface + SessionResolver (DEFERRED to Phase 3)
Deferred deliberately. The real `SessionResolver` is CLI session-targeting, not
an execution backend, and wiring JIT into the session lifecycle is the design's
Phase 3 goal (FileWatcher + Compiler + SessionResolver routing structural edits
to JIT-link). A richer API (`JITLinkResult`/`Symbol`) has no consumer in Phase 1,
the tests already drove the minimal `JITSession` surface (`addObject`,
`address(of:)`, `call`). Adding types now would be speculative. Let the Phase 3
daemon consumer pull whatever API it needs.

## Phase 1 status: COMPLETE

The JIT-link mechanism is validated end to end in-process. SP0d (plugin + shared
`LLJIT`, sessions as `JITDylib`s), SP1 (all six POC scenarios under path A), SP2
(`Compiler.compileObject`), and SP3 (re-resolution) are done. SP4 is unnecessary
and SP5 is deferred. 14 tests, stable under the parallel runner.

## Scope boundaries

- **Phase 1 (this branch):** SP1–SP5 in-process inside the test runner / daemon.
- **Deferred Phase 2+:** out-of-process agent + `SimpleRemoteEPC`; the sidecar
  symbol-discovery format (§3); patch-point publishing / `write_mem`; LLVM
  bundling; iOS device support; in-place patching.

## Immediate next step

SP0d-A. Build the `JITSession` C++ type and handle ABI, then port the witness and
dynamic-cast tests onto it (SP0d-B). Only after the session lands and both tests
pass without a leak hack do we move to SP1.

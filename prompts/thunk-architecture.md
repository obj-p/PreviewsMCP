# Thunk architecture

PreviewsMCP recompiles every Swift source in the user's target on every structural hot-reload (see
`Compiler.swift:128-141`, `SPMBuildSystem.swift:548-582`). On large SPM modules this takes 10+ seconds —
roughly one cold target build per edit. Xcode Previews avoids this by compiling a single "thunk" per
`#Preview` and linking it against pre-built module artifacts (`docs/reverse-engineering.md:498-507,
559-563`). This document specifies how PreviewsMCP gets the same behavior using a public-API mechanism
(`@_dynamicReplacement`), plus the research path for adopting Apple's own JIT executor stack later.

> **Verdict note (JIT-executor research spike, 2026-05).** The JIT-executor research spike
> (see [`prompts/jit-executor-findings.md`](jit-executor-findings.md)) returned verdict #1:
> **buildable; supersedes thunk for the product target.** Apple's preview-runtime JIT-link
> engine (`XOJITExecutor.framework`) is statically linked LLVM ORC + JITLink behind a
> Swift/XPC façade; PreviewsMCP can build the same architecture on public LLVM ORC. The W2
> POC demonstrated Swift function override, protocol witness dispatch, TLVs / `swift_once`
> globals, ObjC interop, and `async` (multi-await) all JIT-link cleanly via the public
> layer. Thunk remains the small-module shipping product *while the JIT executor builds
> out* (multi-quarter follow-on); it is not the long-run architecture. See the findings
> doc for the evidence trail, the four-product-properties scoring, and pre-implementation
> TODOs (W3 patch-point dtrace, ObjC classlist plugin, large-module scaling spike).

## Goal / non-goals

**Goal.** Reload time proportional to the size of the preview file, not the size of the target. Cost of
`preview_switch` between previews in the same file approaches zero. Behavioral parity with Xcode's three
update tiers (small/middle/large, `docs/reverse-engineering.md:559-563`).

**Non-goal (for the first version).** Use Apple's JIT executor (`XOJITExecutor`, `PreviewsInjection`,
`PreviewsPipeline`). Captured as a future research direction at the end of this document.

**Hard prerequisite.** This entire design pivots on `@_dynamicReplacement(for:)` working as the
body-swap mechanism for every preview shape PreviewsMCP supports (`#Preview`, `PreviewProvider`,
`@Previewable`, UIKit/AppKit bodies). The viability spike is open work — see
[`@_dynamicReplacement` viability spike](#_dynamicreplacement-viability-spike). Until that spike
confirms each preview shape, the design here is provisional for `#Preview { ... } ` returning
`some View` only.

## Architecture

Three dylibs per session, with distinct rebuild lifecycles:

```
libPreviewsRuntime.dylib   ── built once at install, dlopened by host at startup
   └─ DesignTimeStore (literal value store with @_cdecl setters)
   └─ __PreviewBridge.wrap helpers (SwiftUI/UIKit/AppKit body coercion)
   └─ __PreviewBodyKindProbe (BodyKind detection)

libUserModule.dylib        ── built at session start, rebuilt only when non-preview files change
   └─ All target sources, compiled with:
        -enable-implicit-dynamic       (every function becomes dynamically replaceable)
        -enable-private-imports        (allows thunk @_private(sourceFile:) access)
        -module-name <UserModule>
        -emit-module-path <UserModule>.swiftmodule
        -lPreviewsRuntime
   └─ Emits both .dylib and .swiftmodule artifacts

libThunk_NN.dylib          ── rebuilt on every preview-file edit
   └─ One source file with N @_dynamicReplacement(for:) shims, one per #Preview
   └─ Compiled with:
        -vfsoverlay <overlay>.json     (maps thunk source path → original preview-file path)
        -module-name <UserModule>Thunk  (distinct from stable — same name causes swiftc to drop
                                         the @_private(sourceFile:) import as a self-import;
                                         empirically verified in dynamic-replacement-spike.md
                                         → "Architectural deltas" §1)
        -I <stable-module-dir> -L <stable-module-dir>
        -lUserModule -lPreviewsRuntime
```

### Lifecycle

| Event | Action |
|---|---|
| Session start | dlopen runtime dylib (no-op if already loaded). Build + dlopen stable module dylib. |
| Preview-file edit, literal-only | Update `DesignTimeStore` over socket / via dlsym. No recompile. |
| Preview-file edit, structural | Compile thunk dylib (one swiftc invocation, one source file). dlopen with `RTLD_NOW`. `@_dynamicReplacement` takes effect at load. |
| Non-preview-file edit | Rebuild stable module dylib, then thunk dylib. Both swapped via dlopen. (See [File watcher split](#file-watcher-split).) |
| `preview_switch` to another `#Preview` in same file | dlsym new bridge entry point in already-loaded thunk dylib. No build, no dlopen. |
| Session stop | dlclose all session-owned dylibs. Runtime dylib stays loaded. |

### Shared state across sessions

The stable module dylib is keyed on the **build target**, not the session. Two `previewsmcp run`
invocations against different files in the same SPM/Xcode/Bazel target should share one
`libUserModule.dylib`; recompiling and reloading it per session would defeat the optimization the whole
architecture is built around.

The daemon holds a `BuildTarget` per `(projectPath, targetName, swiftcFlagsHash)` (see
[`modularization.md`](modularization.md) → "Targets vs sessions"). Sessions attach by ID; the first
attach builds the stable dylib, subsequent attaches reuse it. The module watcher (non-preview file
edits) is per-target — one watcher per attached target, not per session — and a rebuild invalidates
every attached session's thunk.

Implications worth pinning down:

- **GC policy.** When a target's refcount drops to zero, do we evict the stable dylib immediately, or
  keep it warm for the likely-next preview against the same target? Suggest: keep warm for ~5 minutes,
  evict on memory pressure or daemon shutdown.
- **Concurrent rebuild.** Two sessions on the same target hit a non-preview file edit at the same
  instant. The rebuild must be serialized per target; both sessions then re-link thunks against the
  new stable dylib.
- **Cross-target previews.** A `#Preview` in module A that renders types from module B is two
  separate targets in our model — but only A needs a thunk; B is consumed as a normal dependency
  resolved via SPM's pre-built `.swiftmodule`. Verify with a test fixture.

### UIKit literal-barrier becomes cheap

Today `LiteralDiffer` returns `.structural` when a changed literal lives inside a UIKit body region
(`docs/preview-fidelity.md` references issue #160). That forces a full unified-compile rebuild on every
UIKit literal edit — slow.

Under the thunk model, "structural reload" means recompiling only the preview file. The UIKit guard is
no longer a performance cliff; it's a correctness check that costs no more than the regular structural
path. Worth keeping the guard for SwiftUI literal-only path purity, but no longer worth optimizing
around.

## Mechanism: `@_dynamicReplacement`

`@_dynamicReplacement(for: <symbol>)` is the Swift runtime mechanism that lets a later-loaded function
body override an earlier one. Pre-Xcode 16 Previews relied on it as its primary hot-swap mechanism
(`docs/reverse-engineering.md:161-167`). Xcode 16+ moved to the JIT executor but kept
`@_dynamicReplacement` functional as a fallback — the doc captures Xcode's own diagnostic confirming this
(line 178: `Falling back to Dynamic Replacement: false`).

For the stable module to accept replacements, **every function must be marked dynamic**. The blanket flag
is `-enable-implicit-dynamic` — applied to the stable-module compile only; the thunk compile doesn't need
it. The cost is one level of indirection on every function call in the stable module: the runtime resolves
the replacement-pointer at each call. For preview builds this is acceptable — the stable module is built
`-Onone -gnone` anyway.

The thunk reaches the stable module's `internal` declarations via `@_private(sourceFile:)` imports, which
require `-enable-private-imports` on the stable-module compile. This is the same pair of flags Apple used
pre-Xcode 16 (`docs/reverse-engineering.md:165`).

### Thunk source shape

For a preview file with two `#Preview` blocks, the generated thunk source looks like:

```swift
@_private(sourceFile: "FeatureView.swift") import UserModule
import SwiftUI

// Replacement body for FeatureView.body, with __designTime* substitutions.
extension FeatureView {
    @_dynamicReplacement(for: body)
    var __preview_body: some View {
        VStack {
            Text(DesignTimeStore.shared.string("#0", fallback: "Feature Screen"))
                .font(.title)
            CounterView()
        }
    }
}

// One bridge entry point per #Preview in the file.
@_cdecl("createPreviewView_0")
public func __createPreviewView_0() -> UnsafeMutableRawPointer { /* … */ }

@_cdecl("createPreviewView_1")
public func __createPreviewView_1() -> UnsafeMutableRawPointer { /* … */ }
```

The thunk does **not** redeclare `FeatureView` — that's the Xcode 16+ pattern, and it depends on the JIT
executor's symbol-override semantics (`docs/reverse-engineering.md:247-263`). Without the JIT executor,
redeclaration would cause symbol collisions at dlopen time. `@_dynamicReplacement` sidesteps the issue:
the thunk supplies *replacement bodies* for symbols that already exist in the stable module dylib.

## VFS overlay

Even though the thunk source isn't a redeclaration of the original file, swiftc's diagnostics and debug
info should point at the user's actual source. We emit a VFS overlay (same format Xcode emits, captured at
`docs/reverse-engineering.md:222-236`) mapping the thunk's on-disk path to the original preview-file
path. swiftc accepts `-vfsoverlay <file>.json` (driver flag, forwarded to the frontend).

```json
{
  "case-sensitive": "false",
  "roots": [{
    "type": "directory",
    "name": "/.../Sources/UserModule",
    "contents": [{
      "type": "file",
      "name": "FeatureView.swift",
      "external-contents": "<workdir>/FeatureView.thunk.swift"
    }]
  }],
  "version": 0
}
```

Together with a `#sourceLocation(file: ..., line: 1)` pragma at the top of the generated thunk, errors,
warnings, and debugger stops land in the user's real source.

## Multi-preview thunk

A single preview file may contain multiple `#Preview` blocks. We compile **one thunk dylib per file**,
emitting one `@_cdecl("createPreviewView_<n>")` bridge per preview. `preview_switch` becomes a `dlsym` of
the next entry point — no recompile, no dlopen. This is a deliberate divergence from Xcode (which emits
one thunk source per preview, `FeatureView.1.preview-thunk.swift`, `FeatureView.2.preview-thunk.swift`,
…). For a non-Xcode tool there's no reason to fragment them; the compile cost is lower with one
invocation, and switching is faster.

## File watcher split

Today's `FileWatcher` watches every source in the build context with one callback. After this work, two
watchers per session:

- **Preview-file watcher.** Watches only the file containing the active `#Preview`. Edit → thunk-only
  rebuild.
- **Module watcher.** Watches every other source file in the target. Edit → stable module rebuild
  followed by thunk rebuild.

Most edits are to the preview file. Stable-module rebuilds remain expensive (Path B from the prior
analysis); the path forward is to apply swiftc's `-incremental` + `-output-file-map` to the stable-module
compile so unchanged files reuse `.o` artifacts (Path C). Path C lands as a follow-up; Path B is the
shippable v1.

## Stale literal state

`DesignTimeStore` lives in `libPreviewsRuntime` and survives every rebuild. On a structural change, the
new thunk may emit different literal IDs (insertions/deletions in the source shift the numbering),
leaving the old IDs as unreachable dictionary entries. This is acceptable — orphans are tiny and
short-lived. If a session accumulates measurable garbage, a prune step on structural rebuild can
intersect the store's keys with the new thunk's literal-ID set. Not in v1.

## Module split (see modularization.md)

The build pipeline (build-system source enumerators, `Compiler`, plus the three new compilers below) is
large enough and conceptually distinct enough to deserve its own module. Extracted as `PreviewsBuild` in
`prompts/modularization.md`:

- `BuildSystem`, `BuildSystemSupport`, `BuildContext`, `Toolchain`
- `SPMBuildSystem`, `XcodeBuildSystem`, `BazelBuildSystem`
- `BuildTarget` *(new)* — daemon-scoped target abstraction; owns stable module dylib lifecycle.
  See modularization.md → "Targets vs sessions" for why this exists.
- `RuntimeDylibBuilder` *(new)* — emits `libPreviewsRuntime` once per platform.
- `StableModuleCompiler` *(new)* — emits `libUserModule.dylib` + `.swiftmodule`.
- `ThunkCompiler` *(new)* — emits `libThunk_NN.dylib`.

`PreviewsCore` retains the truly-core types: parser, traits, body kind, literal differ/region/info, file
watcher, the `DesignTimeStore` source template, the `PreviewBridgeSource` template, `DylibLoader`,
`PreviewSessionHandle` (protocol).

## iOS host-app wire protocol

Today the iOS host receives one dylib path over the socket and dlopens it
(`HostAppSource/HostApp.swift`, socket-receive path). Under the three-dylib model the host needs to
manage:

- **Runtime dylib** — delivered once at host launch, dlopened with `RTLD_GLOBAL` so
  `DesignTimeStore` and bridge symbols are visible to subsequently loaded dylibs.
- **Stable module dylib** — delivered at session start, dlopened with `RTLD_GLOBAL`. Swapped on
  non-preview file edits. dlclose'ing the old one races any retained types in the running scene; need
  a controlled-teardown protocol.
- **Thunk dylib** — delivered on every structural edit. dlopen takes effect;
  `@_dynamicReplacement` symbols override the stable module's bodies at load time.

Wire-protocol changes the design needs to specify:

- New message types for runtime-dylib delivery (or fold into the first `session_start` payload).
- Distinct signaling for stable-dylib swap vs thunk-dylib swap — the host's teardown sequence differs.
- Code-signing of each dylib before transfer (three signs per non-preview edit, two per preview edit).
  Possibly batch-sign at compile time and ship the signed bytes.
- RTLD flag negotiation: stable + runtime want `RTLD_GLOBAL` so the thunk can resolve symbols;
  thunk wants `RTLD_NOW` to surface unresolved symbols at load.

**Status: open.** Another agent will produce a detailed wire-protocol design for the three-dylib
delivery, covering message types, ordering guarantees, and the teardown sequence on stable-dylib
swap. Output should be a self-contained spec consumable by the iOS host-app implementation.

## `@_dynamicReplacement` viability spike

The architecture commits to `@_dynamicReplacement(for:)` as the body-swap mechanism. Before any of the
implementation work begins, we need to confirm replacement targets exist (and dynamic replacement
actually takes effect) for every preview shape PreviewsMCP supports:

| Preview shape | Replacement target hypothesis | Verified? |
|---|---|---|
| `#Preview { FeatureView() }` — `some View` body | Macro-expanded `static var body` on the generated `PreviewRegistry` conformance | open |
| `#Preview { … }` — UIKit `UIView` / `UIViewController` body via `__PreviewBridge.wrap` overload | Same `static var body` returning a SwiftUI wrapper around the UIKit view | open |
| `PreviewProvider` (legacy) — `static var previews: some View` | The `previews` static var directly | open |
| `@Previewable` properties in `#Preview` | Properties hoisted into the macro-generated closure — replacement boundary unclear | open |
| AppKit `NSView` / `NSViewController` (macOS) | Not currently in scope; flagged in `PreviewBridgeSource` macOS path | n/a |

The spike output: synthetic SPM fixtures for each row, a minimal `@_dynamicReplacement` shim that
swaps a single literal, and a runtime assertion that the swapped value is visible. The table above
gets filled in with concrete replacement-target identifiers (mangled or unmangled) per shape.

If any row turns out *not* targetable, the architecture needs a per-shape fallback (e.g., the
unified-compile path stays available for `PreviewProvider`-only files). The cost of that fallback is
acceptable as long as `#Preview` (the modern, dominant shape) works.

**Status: open.** Another agent will execute this spike. Expected output: a follow-up doc
`prompts/dynamic-replacement-spike.md` with the filled-in table plus the test fixtures pushed to
`Tests/PreviewsCoreTests/`.

## Migration plan

1. **Build runtime dylib.** Convert `DesignTimeStoreSource` and `PreviewBridgeSource` from inline source
   templates (`Sources/PreviewsCore/DesignTimeStore.swift`, `PreviewBridgeSource.swift`) into a real
   `libPreviewsRuntime.dylib` shipped alongside the binary. Two flavors: macOS-native and
   iOS-simulator.

2. **Extract `PreviewsBuild`** (per modularization.md).

3. **Land `StableModuleCompiler` + `ThunkCompiler`** alongside today's unified `Compiler`. Gate the new
   path behind a session-level config flag (default off). The unified path remains the fallback for
   anything the new path can't handle.

4. **Wire the two-watcher split.** Preview-file watcher uses `ThunkCompiler`; module watcher uses
   `StableModuleCompiler` → `ThunkCompiler`.

5. **Measure.** Pick 2–3 large open-source SPM projects with `#Preview` blocks. Compare structural-reload
   wall time and CPU time before / after, with the same warm session.

6. **Default the flag on,** then remove the unified compile path once the new path covers every supported
   build system.

## Risks

- **`-enable-implicit-dynamic` perf cost.** Every function call in the stable module goes through a
  replacement-pointer indirection. Acceptable for `-Onone` debug builds, but worth measuring; if it
  noticeably affects preview launch time, may need to scope dynamism narrower (which means a more
  surgical compile flag set per file).
- **`@_private(sourceFile:)` is underscored.** Stable across recent Swift toolchains, but not a
  guaranteed API. If it breaks, fall back to `@testable import` + `-enable-testing` on the stable build.
- **Per-platform code-signing.** Three dylibs to sign instead of one. For iOS simulator builds the
  thunk dylib must be signed each rebuild — already on the existing hot-reload critical path, so no new
  problem, just more invocations.
- **Cross-module preview cases.** A preview in module A rendering types from module B. Stable-module
  build for module A already handles this via SPM's dependency resolution; the thunk pipeline inherits
  that. Worth a test fixture.
- **`-vfsoverlay` driver behavior.** swiftc accepts the flag, but corner cases with module-map lookups
  inside overlay roots can be surprising. Plan for a working test before relying on it for diagnostics.
- **Bazel + `-enable-implicit-dynamic` injection.** Our SPM/Xcode build paths shell out to `swiftc`
  directly so we control flags. The Bazel path defers more to `rules_swift`; injecting
  `-enable-implicit-dynamic` likely requires the user to add `copts` / `swiftc_options` to their
  target's BUILD rule — i.e., asks the user to modify their config. Alternatives: a Bazel aspect that
  applies flags at our request, or a documented "add this line to BUILD" step. Worth a feasibility
  spike before claiming Bazel parity for this architecture.

## Future direction: replace `@_dynamicReplacement` with the JIT executor

> **Superseded by the JIT-executor research spike — see verdict note at the top of this
> doc and [`prompts/jit-executor-findings.md`](jit-executor-findings.md).** The spike
> answered the questions in this section: Apple's JIT runtime IS LLVM ORC + JITLink
> (Q6 closed); the "three plausible angles" framing below (Angles A/B/C — drive Apple's
> agent, RE the OOPJit format, link `PreviewsPipeline.framework`) was reframed against
> "build our own on public LLVM ORC" per `prompts/jit-executor-research.md`, and that
> reframe verdict came back positive. The remainder of this section is preserved as
> historical context for how the question was originally framed; it is no longer the
> active research direction.

Xcode 16+ uses Apple's `XOJITExecutor` to JIT-link thunk objects against pre-built module objects with
override semantics — strictly faster than `@_dynamicReplacement` because there's no per-call indirection
in the stable module and no `-enable-implicit-dynamic` flag. The reverse-engineering doc covers what's
visible:

- `PreviewsPipeline.framework` (15-step build pipeline, `docs/reverse-engineering.md:569-577`)
- `PreviewsInjection.framework` + `XCPreviewAgent.app` (host/agent runtime,
  `docs/reverse-engineering.md:130-137, 581-622`)
- OOPJit code-page format (`docs/reverse-engineering.md:439-457`)
- `HostAgentSystem` wire protocol (`docs/reverse-engineering.md:201-209, 293-302`)

Unlike `CoreSimulator.framework` (a self-contained library we already link via `SimulatorBridge`), the
JIT executor isn't a library — it's a runtime stack with a private wire protocol and a private build-
artifact format. Three plausible angles to research:

### Angle A — Drive Apple's `XCPreviewAgent` directly

Launch Apple's signed `XCPreviewAgent.app` ourselves with `__PREVIEWS_JIT_LINK` set, impersonate Xcode
over the `HostAgentSystem` pipe, and feed it OOPJit code pages. Blocked on producing the inputs (see B
or C). Once those are available, this is the easiest delivery vehicle since the agent + private
frameworks are already signed and shipped by Apple.

### Angle B — Reverse-engineer the OOPJit code-page format

Produce ARM64 code pages directly from swiftc `.o` output (or by hand-assembling). The format is raw
machine-code pages, not Mach-O (`docs/reverse-engineering.md:441`). High RE cost: ARM64 + Swift runtime
ABI + per-Xcode-version drift. Probably months of work, ongoing maintenance per Xcode release. Most
fragile of the three angles.

### Angle C — Link `PreviewsPipeline.framework` and drive its build steps from our process

`PreviewsPipeline` exposes a 15-step pipeline (`WorkCollectionStep`, `WorkspaceBuildStep`, …,
`LaunchThunksStep`). Most likely the right path: Apple's own producer code, invoked from outside
Xcode-host. Real risks: the steps probably assume Xcode-host context (workspace state, NSKeyedArchiver-
encoded scheme info — the doc captures Xcode sending these as messages 1, 2, 5 at line 207). May need to
mock that context, or extract just the codegen-relevant steps.

### Suggested research environment

A separate macOS VM with **SIP disabled** unlocks the most useful techniques and keeps the security
concession isolated from a daily-driver machine:

- `dtrace` on `Xcode`, `XCPreviewAgent`, `previewsd`, and `PreviewShellMac` during a real preview
  session — extends what `docs/reverse-engineering.md:43-87` already does, but with full coverage of
  Apple processes.
- `lldb` attach to running `XCPreviewAgent` to inspect JIT executor state at `__previews_injection_*`
  entry points.
- `frida-trace` or similar for live function-call tracing.
- `class-dump-swift` / `class-dump` on the 12 host-side `PreviewsPipeline.framework` siblings (doc line
  107-122).

### Starting points

1. Dump every export of `Xcode.app/Contents/SharedFrameworks/PreviewsPipeline.framework` via
   `dyld_info -exports … | xcrun swift-demangle`. Look for public initializers on the 15 step types.
2. Inspect what `XCPreviewAgent` reads on launch (already partially covered in
   `docs/reverse-engineering.md:201-209` — message 2 is an `NSKeyedArchiver`-encoded workspace state).
   Replicate the minimum subset our use case needs.
3. Build a one-shot harness that imports `PreviewsPipeline`, invokes `WorkCollectionStep` with synthetic
   input, and sees how far the pipeline runs before it asks for something we don't have.

If Angle C succeeds, replacing the `@_dynamicReplacement` path is mostly a swap of the thunk-compile +
dlopen steps with "produce OOPJit pages + send via `HostAgentSystem` to a launched
`XCPreviewAgent`." The runtime-dylib + stable-module-dylib + file-watcher split survive unchanged; only
the structural-reload mechanism is replaced.

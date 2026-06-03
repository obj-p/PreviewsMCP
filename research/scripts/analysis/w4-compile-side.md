# W4 compile-side capture — does Apple recompile one file or the whole module?

**Verdict: ONE file.** On a SwiftUI edit Xcode recompiles only the changed file
against the already-built rest of the module. This holds for every edit kind
swept (body-literal, structural, new-file) and on both the build-system
incremental path and the Previews canvas thunk path. Plan gap **G1's premise
(single-file incremental against a prebuilt module) is CONFIRMED.**

Raw capture: [`../data/w4/w4-compile-trace.txt`](../data/w4/w4-compile-trace.txt).
Companion dispatch-side note: [`w3-empirical-capture.md`](w3-empirical-capture.md).

## TL;DR

- M1 — invocation scope: **1 file recompiled** per edit, not the module.
  Measured directly by object-file mtime diff: 1 of 61 objects rebuilt for a
  body edit, a structural edit, and a new-file edit alike.
- M2 — input scope: the driver is handed the **full file list** (all 61 files)
  for type-checking, but `-incremental` + the output-file-map restrict
  swift-frontend to the changed file's object. Dependency modules are reused as
  prebuilt `.swiftmodule`s (`-experimental-emit-module-separately`, `-I`).
- M3 — wall-clock: **~1.3 s** save-to-rebuilt for the build-system path on a
  61-file target. The canvas path is faster still and, for literal-only edits,
  needs no recompile at all (see "design-time" below).
- Caveat honored: path count != recompile scope. "All files listed with
  one primary" IS single-file incremental, exactly as the seed prompt warned.

## Method

Build host (this Mac), not the W3 VM — the VM was unnecessary because the build
host runs the identical Xcode 26.2 toolchain and the compile question is
host-side. SIP is on, so no dtrace; instead two converging tracks:

1. **Track A — live experiment.** A generated 60-file macOS framework with one
   `#Preview` view. Snapshot every `*.o` mtime, make one edit, incremental
   `xcodebuild`, diff mtimes to see which objects actually recompiled. The
   incremental swiftc command line is read from the build log for M2.
2. **Track B — thunk artifacts.** Read the Xcode Previews intermediates left by
   prior real canvas sessions (`PreviewTestApp`, `MultiModuleTest` in
   DerivedData). These reveal the hot-reload compile mechanism directly.

## M1 / M2 — Track A (build-system incremental)

| Edit | Change | Objects recompiled | Wall-clock |
|------|--------|--------------------|------------|
| body literal | `"hello world 0"` → `"1"` | `ToDoView.o` (1/61) | 1.25 s |
| structural | add a method to the view | `ToDoView.o` (1/61) | 1.38 s |
| new file | add `Filler61.swift` | `Filler61.o` (1/61) | 1.39 s |

Quoted driver invocation (key flags):

```
swiftc -module-name W4 @.../W4.SwiftFileList -c \
  -enable-batch-mode -incremental -output-file-map ... \
  -emit-module-path .../W4.swiftmodule -experimental-emit-module-separately
```

`W4.SwiftFileList` contains all 61 paths. `-incremental` + the output-file-map
are what make swift-frontend rebuild only the one changed object. In the
cross-module `MultiModuleTest` build, each module emits its own `.swiftmodule`
and downstream modules consume it as a prebuilt input — so an edit in one module
recompiles one file there and relinks, never the dependency modules.

Dependency-fan-out note: the filler files are independent, so each edit's blast
radius is the single edited file. An edit that changes a **public declaration
other files reference** would also recompile those dependents (still a subset,
not the whole module). The common preview case — editing a `View` body — is the
body-literal row: exactly one file.

## M1 / M2 — Track B (Previews canvas hot-reload)

The canvas path is even narrower than `xcodebuild`. For the single edited file
Xcode generates a **thunk** and compiles only that:

- `ContentView.1.preview-thunk.swift` — a rewritten copy of the one edited file.
- `vfsoverlay-ContentView.1.preview-thunk.swift.json` — a VFS overlay that maps
  the real `ContentView.swift` path to the generated thunk, so the compiler
  substitutes exactly one file while the rest of the module stays prebuilt.
- `#sourceLocation(file: ".../ContentView.swift", ...)` keeps diagnostics mapped
  to the real source.

Inside the thunk, every literal is rewritten to a **design-time** call:

```swift
VStack(spacing: __designTimeInteger("#7210_0", fallback: 20)) { ... }
Button(__designTimeString("#7210_1", fallback: "Increment")) { ... }
```

`__designTimeString/Integer/Float/Boolean` let Xcode inject new literal values
at runtime against the compiled fallback — so a literal-only edit can refresh
the preview **without any recompile**. The `.0.`→`.1.` counter on the thunk
filename bumps per edit, and in multi-module builds the thunk is per-module,
per-file (`FeatureModule/FeatureView`, `ViewLibrary/Previews`). These compiles
are run by the preview build service out-of-band and do not appear in
`Logs/Build`, matching the seed prompt's XCBBuildService warning.

### Mechanism: PreviewRegistry re-entry, NOT dynamic replacement

Inspecting the compiled thunk object (`nm` + `otool` on
`ContentView.1.preview-thunk.o`) settles how the new code is dispatched:

| probe | result |
|-------|--------|
| dynamic-replacement symbols (`@_dynamicReplacement`) | 0 |
| `__swift5_replace` section | 0 |
| `PreviewRegistry.makePreview()` symbols | 4 |

The thunk does **not** patch the original body via dynamic replacement. It
compiles a fresh `DeveloperToolsSupport.PreviewRegistry` conformance whose
`makePreview()` builds the edited view, and the (respawned) preview host calls
that. This corroborates W3's dispatch finding from the compile side: the
body-edit path is **recompile-a-new-entry + respawn**, not in-place patching.
(Note for the JIT plan: this is evidence *against* leaning on Swift dynamic
replacement as "what Apple does" — Apple does not, at least for body edits in
26.2.)

## M3 — wall-clock

Build-system incremental: **~1.3 s** save→rebuilt object on 61 files (compile
only; the canvas render/respawn that W3 measured is additive). The
design-time-literal path skips compilation entirely for literal edits, which is
the sub-second case users feel. A true save→pixels number needs the live canvas
and is W3's domain (respawn-dominated); W4's scope is the compile step.

## What this means for the JIT executor plan

- **G1 holds.** A single-file incremental compile against a prebuilt
  `.swiftmodule` is real and is what Apple does. The JIT executor's
  <200 ms target is plausible on the compile side: one file, not the module.
- **G2 (prebuilt-module reuse) is also supported** — `-experimental-emit-module-
  separately` + per-module `.swiftmodule` inputs are exactly the "compile one
  file, link against prebuilt modules" shape the plan assumes.
- **New angle for the executor:** Apple's literal fast-path is *data injection*,
  not recompilation (`__designTimeString` + fallback). For literal-only edits a
  JIT executor could mirror this and skip compile entirely. Worth a follow-up.

## Apple's thunk-compile argv — CAPTURED

The exact `swift-frontend` argv is now captured live, not just reconstructed.
Full command line in
[`../data/w4/w4-thunk-argv.txt`](../data/w4/w4-thunk-argv.txt). It was grabbed
on the host with `capture-thunk-compile.sh` (sudo-free `ps` poller) while
editing the `preview-fixture` canvas. The catch trick: a body edit on a
*deliberately heavy* file (~250 filler structs) stretches the compile to ~2.7s,
long enough for `ps` to see the otherwise-millisecond frontend. The argv
confirms, from Apple's own command, what the reconstruction predicted:

- **Single primary:** exactly one `-primary-file ContentView.swift` (the edited
  file); the other target file is a plain secondary input. 1 primary of 2
  sources — single-file incremental.
- **VFS substitution:** `-vfsoverlay vfsoverlay-ContentView.1.preview-thunk.swift.json`,
  output `-o ContentView.1.preview-thunk.o`.
- **Prebuilt-module reuse (G2):** `-disable-implicit-swift-modules` +
  `-explicit-swift-module-map-file …PreviewFixture-dependencies-5.json` +
  `-I …/Build/Products/Debug`. Dependencies are consumed as prebuilt explicit
  modules — direct evidence for the plan's G2 assumption.
- **No dynamic replacement:** no `-enable-implicit-dynamic`, no
  dynamic-replacement flag. Reconfirms the PreviewRegistry-reentry mechanism.
- `-load-resolved-plugin …PreviewsMacros…` expands `#Preview`; `-Onone`,
  `-swift-version 6`; experimental features `DebugDescriptionMacro`,
  `OpaqueTypeErasure`.

GUI-driving note (for whoever automates this next): the preview only rebuilds on
a *genuine* editor change event. AppleScript `set text of source document` does
NOT fire it; a real typed keystroke does. The canvas must also be visible —
a hidden canvas never compiles.

## What this does NOT close

- All capture is macOS 26.2 / Xcode 26.2. Not swept across Xcode versions.
- Dependency fan-out for public-API edits was reasoned, not measured at scale;
  the swept edits all had blast radius 1.

## Provenance

Track A: `/tmp/w4-compile` experiment, 2026-06-02, Xcode 26.2 (17C52), this
host. Track B: `DerivedData/PreviewTestApp-*` and `DerivedData/MultiModuleTest-*`
preview intermediates from prior real sessions (project source under
`~/Projects/reverse-previews/`). Full numbers and quoted lines in
[`../data/w4/w4-compile-trace.txt`](../data/w4/w4-compile-trace.txt).

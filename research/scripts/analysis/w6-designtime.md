# W6 — Canvas thunk argv + design-time literal injection model

Two W4 leftovers about the **canvas hot-reload path** (the one users feel):
M1 the exact thunk `swift-frontend` argv, and M2 the design-time literal
injection mechanism that lets a literal-only edit refresh with **no recompile**.
M3 is the literal-vs-structural boundary.

## M1 — thunk argv (closed; narrower than the build path)

Captured live (not reconstructed) during W4:
[`../data/w4/w4-thunk-argv.txt`](../data/w4/w4-thunk-argv.txt), recap in
[`../data/w6/w6-canvas-argv.txt`](../data/w6/w6-canvas-argv.txt). The canvas
thunk compile uses a single `-primary-file` (the edited file) + the other target
files listed explicitly + `-vfsoverlay` + `-disable-implicit-swift-modules` +
an explicit module map. It has **no** `-filelist`, **no** `-incremental`, **no**
batch mode. So the canvas path is not swiftc-incremental — it is a single-shot
compile of one file against prebuilt explicit modules, i.e. Apple already runs
the W5/W7 "split" shape on the compile side.

## M2 — design-time injection lifecycle

Apple's mechanism has three layers; this project re-implements all three
(`DesignTimeStore`, `LiteralRegionClassifier`, `LiteralDiffer`,
`ThunkGenerator`), which is the clearest cross-check.

### 1. Generate — IDs at thunk-compile time

The thunk rewrites each eligible literal into a call:

```swift
Text(__designTimeString("#7210_0", fallback: "Increment"))
VStack(spacing: __designTimeInteger("#7210_1", fallback: 20)) { ... }
```

SwiftUI exports the family (from the SDK `.swiftinterface`):

```
func __designTimeString<T>(_ key: String, fallback: T) -> T where T: ExpressibleByStringLiteral
func __designTimeInteger<T>(_ key: String, fallback: T) -> T where T: ExpressibleByIntegerLiteral
// + Float / Boolean, plus an OSLogMessage overload
```

The key `#7210_0` is **per-file salt (`7210`) + sequential index (`_0`)**: stable
across edits as long as the file's literal *sequence* is unchanged, so a value
swap re-targets the same key. The `fallback:` is the original literal, compiled
in — so the thunk runs standalone (no store ⇒ returns fallback). This project
uses a simpler `#0`/`#1` scheme (`LiteralInfo.LiteralEntry.id`) but the same
shape.

### 2. Store — keyed value table read at runtime

Under Previews, `__designTimeString(key, fallback)` resolves `key` against a
runtime value table; hit ⇒ injected value, miss ⇒ fallback. This project's
`DesignTimeStore` is a faithful model: an `@Observable final class` holding
`values: [String: Any]`, with `string/integer/float/boolean(_ id:, fallback:)`
readers (note the `CGFloat` overloads for `spacing`/`padding`/`cornerRadius`).
Being `@Observable` is what makes a value change drive a SwiftUI re-render
without recompiling.

### 3. Re-inject — value delivery to the running agent, no recompile

On a literal-only edit Xcode does **not** recompile. It sends the new value,
keyed by the same ID, to the running preview agent. Apple's transport is the
`PreviewsInjection` framework `EntryPoint` (exports in
[`../data/w3/PreviewsInjection-exports.txt`](../data/w3/PreviewsInjection-exports.txt)):

- `EntryPoint.handleHostMessageStream(_:instance:)` and
  `handleEndpoint(_:context:)` — an XPC (`NSXPCListenerEndpoint`) channel from
  Xcode to the agent.
- `UpdatePayload` / `UpdateInputs` / `cancelUpdate` — the value-update verbs
  carried over that channel (the literal-only fast path).
- `__previewsInjectionPerformFirstJITLink` / `JITLinkEntrypoint` /
  `RunUserEntryPoints` — the **recompile** path (structural edits), which JIT-links
  a freshly compiled thunk (W4/W7) and re-runs the entry point.

This project mirrors the update verbs with `@_cdecl` setters compiled into the
preview dylib — `designTimeSetString/Integer/Float/Boolean(id, value)` — which
the host calls to mutate `DesignTimeStore.shared.values[id]`; `@Observable` then
re-renders. So: **literal edit → set value by ID over the channel → observed
re-render, zero compile, zero respawn.**

## M3 — literal-only vs structural boundary

`LiteralDiffer.diff(old:new:)` decides the path by masking literals to a
**skeleton** (source with literal tokens removed) and comparing:

| condition | path |
|-----------|------|
| skeletons differ (any non-literal change) | **structural** → thunk recompile + JIT-link/respawn |
| literal *count* differs | **structural** |
| skeletons equal, only literal *values* changed, all in SwiftUI regions | **literal-only** → inject by ID, no recompile |
| a changed literal is in a **UIKit** region | downgraded to **structural** |

The UIKit downgrade (issue #160) is the sharp edge: UIKit code
(`UIView`/`UIViewController` subclasses, `UIView(Controller)Representable`
conformances, or a member with a UIKit return/var type — `LiteralRegionClassifier`
walks parents for these) reads the store value **once at construction** and never
observes mutation, so injection silently no-ops there. Those literals must take
the recompile path. Swept edit kinds: string/number/bool value change in a
SwiftUI body → injection; same change inside a `UIViewRepresentable` → recompile;
adding/removing a view, changing a type or modifier chain, or adding a literal →
skeleton changes → recompile. This matches the live W4 observation (literal
"edit me 0"→"1" produced no thunk recompile; structural `.bold()` produced a
fresh thunk).

## Implications for the JIT executor

- The literal-only path is the cheapest tier: **no compile, no respawn** — just a
  keyed value push to the agent. The executor should classify edits exactly as
  `LiteralDiffer` does and only fall to the W7 JIT-link path on structural (or
  UIKit-region) changes.
- The ID scheme must be stable across edits (per-file salt + sequence) so a value
  swap re-targets the same key; a literal *count* change invalidates it and is
  correctly treated as structural.
- The UIKit-region caveat bounds the fast path: it is sound only for
  SwiftUI-evaluated reads. This is already encoded here (#160) and should stay a
  hard gate.

## What this does NOT close

- Apple's exact wire format for `UpdatePayload` (field layout) was read from
  symbol names, not decoded from a live XPC capture; the value-by-ID semantics
  are confirmed via the SwiftUI `__designTime*` signatures + this project's
  working mirror, but the on-the-wire bytes were not dumped.
- Whether Apple keys purely by the `#salt_n` string or also by source range was
  not separated; the project keys by ID string and it works.
- Xcode 26.2 / SwiftUI from that SDK only.

## Provenance

Apple symbols: SDK SwiftUI `.swiftinterface` (`__designTime*`),
`../data/w3/PreviewsInjection-exports.txt`. Project model:
`Sources/PreviewsCore/{DesignTimeStore,LiteralInfo,LiteralRegionClassifier,LiteralDiffer,ThunkGenerator}.swift`.
Thunk argv: [`../data/w6/w6-canvas-argv.txt`](../data/w6/w6-canvas-argv.txt).

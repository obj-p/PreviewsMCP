# `@_dynamicReplacement` viability spike — findings

Empirical verification of whether `@_dynamicReplacement(for:)` can body-swap each
preview shape PreviewsMCP supports. Promoted from step 3 of `prompts/README.md` and
step 2 of `prompts/thunk-architecture.md` → "`@_dynamicReplacement` viability spike".

**Status:** complete (8/8 rows verified). The work is preserved as research,
not merged forward — see the strategic note at the end for the reason.

**Preservation:**
- Branch: [`spike/dynamic-replacement`](https://github.com/obj-p/PreviewsMCP/tree/spike/dynamic-replacement)
- Closed PR (with full per-row synthesis in the description):
  [#178](https://github.com/obj-p/PreviewsMCP/pull/178)
- Test fixtures on that branch:
  `Tests/PreviewsCoreTests/DynamicReplacementSpike/`
  (one file per row + `SpikeHarness.swift`)
- Toolchain pinned: Swift 6.2.3 / Xcode 26.2 / `arm64-apple-macosx26.0`

## TL;DR

| Row | Shape | Replaceable? | Replacement target |
|---|---|---|---|
| 1 | Free `dynamic func` | ✅ | the function itself |
| 2 | `PreviewProvider.previews` | ✅ | `static var previews` getter |
| 3 | `#Preview { UserView() }` | ✅ via the user view | `UserView.body`, **not** the macro expansion |
| 4 | `#Preview { NSView() }` (AppKit) | ✅ via the user function | the user function the closure delegates to |
| 5 | `@Previewable @State` (as-written) | ⚠️ partial | only user view bodies referenced from inside; the `@Previewable` declaration + closure-level structure are **not** replaceable |
| 6 | Inline `#Preview` after wrapper synthesis (multi-cycle) | ✅ | the synthesized `__PreviewWrapper_<n>.body`; last-write-wins across multiple thunk dlopens |
| 7 | `@Previewable` lifted to wrapper `@State` (v2 mitigation) | ✅ | the synthesized wrapper's `body`; replacement body reads the wrapper's `@State` storage directly |
| 8 | `@State` default-value edits via factory replacement | ✅ via factory (init replacement is **unsupported**) | a free `makeInitialWrapper()` function the thunk generator emits alongside each wrapper |

Verdict: **holdover track is viable.** All three mitigations the spike
proposed (inline-body wrapper synthesis, `@Previewable` lifted to wrapper
`@State`, default-value edits via factory replacement) have been empirically
validated — rows 6, 7, and 8 respectively.

**What requires a stable-module rebuild collapses to one structural case:**
adding or removing a `@Previewable` declaration. That changes the wrapper
struct's stored-property layout, and Swift extensions cannot add stored
properties, so the thunk physically cannot extend it.

Edits that **stay on the fast path** (thunk-only, no stable rebuild):
- body content changes (any shape)
- modifier-chain edits
- inner-view substitutions
- `@State` initial-value changes (via factory replacement, row 8)
- inline-body changes (via wrapper synthesis, row 6)

## Standardized swiftc flag set (canonical)

**Stable module:**
```
swiftc -emit-library -emit-module
       -module-name <UserModule>
       -Xfrontend -enable-implicit-dynamic
       -Xfrontend -enable-private-imports
       -Onone -g -sdk <SDK>
       -o lib<UserModule>.dylib <sources>
```

Important: both `-enable-implicit-dynamic` and `-enable-private-imports` are
**frontend-only** flags and require the `-Xfrontend` prefix when passed through
the driver. The bare flags are rejected with
`error: unknown argument: '-enable-implicit-dynamic'`.

**Thunk module:**
```
swiftc -emit-library
       -module-name <UserModule>Thunk          ← distinct from stable
       -Onone -g -sdk <SDK>
       -I <stable-dir> -L <stable-dir> -l<UserModule>
       -Xlinker -rpath -Xlinker <stable-dir>
       -o libThunk_<n>.dylib <thunk source>
```

Thunk source pattern:
```swift
@_private(sourceFile: "<original-source-basename>.swift") import <UserModule>

extension <UserView> {
    @_dynamicReplacement(for: body)
    public var __replacement: some View { … }
}
```

## Architectural deltas (corrections to `prompts/thunk-architecture.md`)

### 1. The thunk must use a **distinct** `-module-name` from the stable

`thunk-architecture.md` line 50 says:
> `-module-name <UserModule>      (same module — needed for private-imports access)`

This is wrong. With the same module name, swiftc treats the
`@_private(sourceFile:) import` as a self-import and silently drops it:

```
warning: file 'thunk.swift' is part of module 'UserModule'; ignoring import
```

The replacement target then fails to resolve:
```
error: replaced function 'spike_target()' could not be found
```

A distinct `-module-name` (e.g. `<UserModule>Thunk`) makes the import succeed and
`@_dynamicReplacement(for: …)` works without qualification. Empirically verified
on Swift 6.2.3 / Xcode 26.2.

### 2. The replacement target hypothesis for `#Preview` is wrong — replace the user view body, not the macro

`thunk-architecture.md` (spike table, row 3) hypothesized:
> Macro-expanded `static var body` on the generated `PreviewRegistry` conformance.

Symbol-table evidence (from `nm -gU | swift-demangle`):

```
T   static <Mod>.$s9<Mod>...PreviewRegistryfMu_.makePreview() throws -> Preview
D   dynamically replaceable variable for static <Mod>.$s9...PreviewRegistryfMu_.makePreview() ...
S   dynamically replaceable key for static <Mod>.$s9...PreviewRegistryfMu_.makePreview() ...
```

The macro does emit a `DeveloperToolsSupport.PreviewRegistry`-conforming type, and
its `makePreview()` IS dynamically-replaceable. But the type's name is mangled
and starts with `$s9…fMu_` — **not a valid Swift identifier**. You cannot write
`@_dynamicReplacement(for: <that-type>.makePreview())` because the type can't be
spelled in source.

Practical strategy (matches Apple's pre-Xcode-16 pattern in
`docs/reverse-engineering.md:161-167`): **the thunk replaces user-named view
bodies, never macro expansions.** The macro stays put across hot-reloads; the
user view's `body` getter — which is dynamically-replaceable via
`-enable-implicit-dynamic` — is what swaps. The macro's render path calls into
the replaced body via normal dynamic dispatch.

### 3. Inline-only `#Preview` bodies — mitigated by build-time wrapper synthesis

A preview like:
```swift
#Preview {
    Text("hi")          // no user-named type
}
```
has its View tree embedded inside the unspellable `makePreview()` closure with no
named replacement target. **Naive `@_dynamicReplacement` cannot hot-swap this.**

However, the thunk generator already rewrites source between user and compile.
Adding a syntactic wrapper-synthesis step closes the gap: detect inline-only
`#Preview` blocks and rewrite them to delegate to a generated named wrapper.

Before (user source):
```swift
#Preview {
    Text("hi")
}
```

After (what the stable module actually compiles):
```swift
public struct __PreviewWrapper_42: View {
    public var body: some View {
        Text("hi")
    }
}

#Preview {
    __PreviewWrapper_42()
}
```

The thunk then replaces `__PreviewWrapper_42.body` on every edit — same fast-path
as the user-delegating case. The wrapper's identity is stable across edits as
long as the `#Preview` block's source-file offset is stable (or we key it by a
syntactic ordinal). Edits to the body re-emit the thunk only; the stable module
stays unchanged.

Cost of this mitigation:
- One synthetic struct per `#Preview` in the stable module — negligible.
- Source-rewrite step in the thunk generator — already part of the design.
- One extra stable rebuild the **first** time a preview file is opened, to
  introduce the wrappers. The first stable rebuild is unavoidable anyway (the
  session needs the stable dylib to exist).

Subsequent inline-body edits go through the fast path. **Empirically confirmed
in row 6** (`InlineWrapperSynthesisDynamicReplacementTests`): two thunks
compiled against the same stable wrapper both successfully replace the body —
last-write-wins on the dispatch table. The multi-cycle case is what makes
wrapper synthesis a fast path rather than a stable rebuild in disguise: the
wrapper struct compiles once, every subsequent edit re-emits only the thunk.

`@Previewable` complication (lifting): if the inline body uses
`@Previewable @State`, the wrapper synthesis needs to lift the property to a
real `@State` on the wrapper struct. **Empirically confirmed in row 7**
(`PreviewableLiftedDynamicReplacementTests`): the lifted form is hot-swappable
end-to-end, and the replacement body reads the wrapper's `@State` storage
directly (`count + 100 == 107` in the test).

`@State` initial-value edits — verified workaround (row 8). Naive intuition
says "compile-time `@State var count = 0` becomes part of the wrapper's
`init()`, and `init()` is dynamically-replaceable per the row 1 / row 5
symbol tables, so just replace it." **Empirically false:** Swift's frontend
rejects `@_dynamicReplacement(for: init())` at source-resolution time, even
with `public dynamic init()` declared explicitly:

```
error: replaced function 'init()' is not marked dynamic
```

The init's binary symbol IS in the dynamically-replaceable list, but the
`@_dynamicReplacement` source-level check has its own list of accepted
targets and structs' inits aren't on it. (Two facts coexist: the metadata is
emitted unconditionally; the source-level check filters.)

**The working workaround** (row 8 validates it): route construction through a
free factory function the thunk generator emits alongside each wrapper.

```swift
public dynamic func makeInitialWrapper() -> __PreviewWrapper_1 {
    return __PreviewWrapper_1(count: 7)
}
#Preview {
    makeInitialWrapper()
}
```

The factory's body is straightforwardly replaceable (row 1 territory). The
thunk emits a new factory that constructs the wrapper with different default
values; edits to `@Previewable @State var count = 0` compile into the
factory's body. No stable rebuild required.

Practical guidance for the thunk generator: **always emit the factory** even
when the wrapper has no `@Previewable` properties. Costs one trivially-
synthesized free function per wrapper and keeps the rewrite shape consistent
across all `#Preview` blocks.

### 4. `@Previewable` declarations are not replaceable; user view bodies referenced from inside still are

`@Previewable` generates a local struct
`__P_Previewable_Transform_Wrapper #1 in closure #1 @MainActor () -> SwiftUI.View
in static <Mod>.$s…PreviewRegistryfMu_.makePreview() throws -> Preview` — a
local type nested inside the closure inside `makePreview()`. Its `body.getter` is
NOT dynamically-replaceable.

What you CAN hot-swap with `@Previewable` in scope: any user-named view's `body`
that the closure delegates to (e.g. `CounterView.body`).

What requires a stable-module rebuild:
- adding/removing a `@Previewable` declaration
- changing the `@State` initial value (it's encoded in the closure)
- restructuring the closure-level expression

Acceptable cost — `@Previewable` is typically configured once per preview and
edited rarely; the inner view's body is what authors iterate on, and it stays
hot-swappable.

## Per-row symbol references (Swift 6.2.3, Xcode 26.2)

For each row, the `dynamically replaceable key for …` symbol confirms the target
is hot-swappable. Names are pinned to this toolchain; macro symbol naming is not
stable Swift API and should be re-verified on Swift updates.

**Row 1 — free function:**
- `dynamically replaceable key for <Mod>.spike_target() -> ()`

**Row 2 — PreviewProvider:**
- `dynamically replaceable key for static <Mod>.MyPreviews.previews.getter : some`

**Row 3 — `#Preview { UserView() }`:**
- `dynamically replaceable key for <Mod>.DummyView.body.getter : some` ← target
- (also exists, but unspellable, hence not usable:
   `dynamically replaceable key for static <Mod>.$s9...PreviewRegistryfMu_.makePreview()...`)

**Row 4 — `#Preview { NSView() }`:**
- `dynamically replaceable key for <Mod>.makeAppKitView() -> AppKit.NSView` ← target

**Row 5 — `@Previewable`:**
- `dynamically replaceable key for <Mod>.CounterView.body.getter : some` ← target (user view body, replaceable)
- `__P_Previewable_Transform_Wrapper`'s own `body.getter` is **not** in the
  dynamically-replaceable list (only present as a regular Text symbol at offset
  0x1974 in the test fixture); the wrapper itself can't be targeted.

**Row 6 — inline-body wrapper synthesis (multi-cycle):**
- `dynamically replaceable key for <Mod>.__PreviewWrapper_1.body.getter : some` ← target
- Two thunks both registered against this key; the runtime resolves to the
  most recently dlopened one. (No assertion fired about a duplicate
  replacement, no crash on second dlopen.)

**Row 7 — `@Previewable` lifted to wrapper `@State`:**
- `dynamically replaceable key for <Mod>.__PreviewWrapper_1.body.getter : some` ← target
- `@State`-backed stored property `count` on the wrapper has its own
  `@_propertyWrapper`-emitted symbols; the body reads through those, and
  the replacement body reads the same backing storage (verified by reading
  the value through both the stable and thunk-replaced bodies).

**Row 8 — `@State` default via factory replacement:**
- `dynamically replaceable key for <Mod>.makeInitialWrapper() -> <Mod>.__PreviewWrapper_1` ← target
- Notable negative: `@_dynamicReplacement(for: init())` is rejected with
  `replaced function 'init()' is not marked dynamic` even with
  `public dynamic init() { … }`; the init's symbol IS in the
  dynamically-replaceable list but the frontend's `@_dynamicReplacement`
  source-resolution stage doesn't accept it as a target.

## Test harness invariants

`SpikeHarness.swift` standardizes:

1. **One stable + one thunk dylib per row.** Both compiled by direct `swiftc`
   invocation (via `Toolchain.swiftcPath()`), no SwiftPM, no SPMBuildSystem.
2. **dlopen ordering:** stable with `RTLD_NOW | RTLD_GLOBAL`, then thunk with
   the same flags. Replacement takes effect at the thunk's dlopen.
3. **Side-channel assertion:** stable body writes
   `nonisolated(unsafe) public var SPIKE_SENTINEL`; a `@_cdecl` wrapper resets
   the sentinel, invokes the dynamic target, and returns the post-call value.
   Tests dlsym the C wrapper and compare before vs. after thunk dlopen. This
   sidesteps SwiftUI/AppKit runtime — we're verifying "the new body fired,"
   not "the new view rendered correctly." Rendering correctness is out of
   scope; that's covered by the existing snapshot tests.

The harness is intentionally crude (inline swiftc args, no abstractions). It is
**not** a prototype for `StableModuleCompiler` / `ThunkCompiler` — those live
in `PreviewsBuild` per `prompts/modularization.md`. The harness's job is to
answer the per-shape viability question and leave behind regression tests that
guard against Swift toolchain updates breaking each row.

## What this spike deliberately did NOT verify

To keep scope tight, the spike skipped:

- **iOS-simulator validation.** The harness compiles for macOS-native only. An
  iOS pass would swap `-sdk iphonesimulator` + `-target arm64-apple-ios-simulator`
  and AppKit → UIKit. The harness invariants are platform-independent. Follow-up.
- **`-vfsoverlay` diagnostic correctness.** Whether errors/warnings/debugger
  stops in the thunk point at the user's source file. Separate, smaller probe;
  only matters when shipping.
- **`-enable-implicit-dynamic` perf cost.** Per-call indirection overhead in the
  stable module. Belongs in the migration plan's "Measure" step
  (`prompts/thunk-architecture.md` → migration plan #5).
- **Bazel-side flag injection feasibility.** `rules_swift` doesn't pass through
  `-enable-implicit-dynamic` by default; already called out as a separate
  feasibility spike in `prompts/thunk-architecture.md` → Risks.
- **iOS code-signing.** Three dylibs to sign instead of one on every reload.
  Iteration cost analysis, not a viability question.
- **Rendering correctness.** The spike asserts "replacement body fired," not
  "the rendered output is what we expected." Snapshot tests cover the latter.

## Toolchain pinning

All verification performed on:
- `swift-driver version: 1.127.14.1 Apple Swift version 6.2.3 (swiftlang-6.2.3.3.21 clang-1700.6.3.2)`
- Target: `arm64-apple-macosx26.0`
- SDK: `MacOSX26.2.sdk`

Macro-emitted symbol names (`$s9...PreviewRegistryfMu_`,
`__P_Previewable_Transform_Wrapper`) are not stable Swift API. Re-verification
recommended on every Swift major-version bump. The spike tests serve as
regression fixtures.

## Implementation guidance for the thunk-architecture work

Based on the findings:

1. **`ThunkGenerator` (or its successor in `PreviewsBuild`) targets user-named
   types.** Walk the preview file's syntax to find each `#Preview` macro
   invocation; emit one `@_dynamicReplacement(for: body)` shim per user-named
   `View` referenced by the closure. The macro itself is left alone.

2. **For inline-only `#Preview` bodies**, the thunk generator synthesizes a
   named wrapper view per `#Preview` block (`__PreviewWrapper_<n>: View`)
   AND a paired factory function (`makeInitialWrapper_<n>()`). The
   `#Preview` closure is rewritten to call the factory. Body edits replace
   the wrapper's `body`; `@State` default-value edits replace the factory.
   Both stay on the thunk-only fast path. See §3 (wrapper synthesis) and
   row 8 (factory replacement) for the rewrite patterns.

3. **`@Previewable` edits trigger stable rebuilds.** Any edit that adds, removes,
   or changes a `@Previewable` declaration falls back to Path B. Edits to the
   user view body referenced from inside the `@Previewable` closure stay on the
   fast path.

4. **The thunk uses `<UserModule>Thunk`, not the user's module name.** Update
   `prompts/thunk-architecture.md` accordingly.

5. **Macro-symbol-name discovery is not required** for the thunk generator —
   it never emits attributes targeting macro-generated symbols. All target
   names come from user source (view declarations, `static var previews`,
   free functions).

## Open follow-ups

- Run the same eight rows under `iphonesimulator` SDK + `arm64-apple-ios-simulator`
  target to confirm parity. Should be a one-flag-set change to the harness.
- If the thunk-architecture track gets committed to: port the harness's
  regression tests to drive the production `StableModuleCompiler` /
  `ThunkCompiler` (in `PreviewsBuild`) instead of inline swiftc invocations.
  The fixtures (source strings) stay; the build-driving code is throwaway.
- Capture the unspellable-macro-type behavior in a Swift Forums post or radar.
  This is a real toolchain UX issue for anyone trying to do dynamic
  replacement of macro-generated code; documenting it publicly may surface
  workarounds we don't know about.

## Why this work is preserved, not merged

The spike answered its empirical question — the mechanism works for every
shape PreviewsMCP supports, the mitigations close the awkward cases, only
adding/removing a `@Previewable` declaration genuinely needs a stable rebuild.

It deliberately did **not** verify four load-bearing risks that decide whether
the holdover ships a real speedup or a marginal one:

1. **iOS codesigning iteration cost.** Three dylibs per non-preview edit, two
   per preview edit. Each codesign call is ~200ms on simulator. Could erode
   the speedup substantially on iOS specifically.
2. **`-enable-implicit-dynamic` perf cost.** Per-call indirection on every
   function in the stable module. Doc says "probably fine for `-Onone` debug
   builds." Unmeasured on real SwiftUI hierarchies.
3. **`-vfsoverlay` diagnostic correctness.** If errors point at the
   synthesized wrapper rather than user source, dev experience regresses
   badly. Unverified.
4. **Bazel `-enable-implicit-dynamic` injection.** `rules_swift` doesn't pass
   the flag through. May require a Bazel aspect or user-side `copts` —
   substantial scope.

Decision (2026-05-17): rather than commit a multi-month build that may be
obsoleted by the JIT track (`prompts/jit-executor-research.md`), the
foundation-first path is preferred. Work that's reusable for either track
(modularization, `StableModuleCompiler`, file-watcher split, `BuildTarget`
abstraction) lands first; the JIT 3-week research timebox runs in parallel;
the thunk-specific pieces (wrapper synthesis, factory emission,
`@_dynamicReplacement` shim generation, VFS overlay, Bazel injection) are
gated on the JIT verdict.

If the JIT track returns "not buildable" or "buildable-alongside," the
holdover gets committed knowing the four risks above — closed with a
1-week measurement spike before scaling implementation. If JIT returns
"buildable-supersedes," the holdover work shipped on
[`spike/dynamic-replacement`](https://github.com/obj-p/PreviewsMCP/tree/spike/dynamic-replacement)
stays as the proof that the path was viable, but isn't taken.

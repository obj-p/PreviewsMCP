# W7 — auto thunk-split feasibility

**Verdict: FEASIBLE for the common case.** An arbitrary target can be auto-split
into a stable module + an editable preview unit without the user restructuring
their package, as long as the preview only reaches `internal`-or-wider
declarations. The editable unit uses `@testable import` to see the stable
module's `internal` types (SwiftUI views are usually `internal`), and edit→relink
stays **flat at ~0.14 s** regardless of stable-module size. The split fails only
when the preview references `private`/`fileprivate` decls, which cross no module
boundary.

Raw probes: [`../data/w7/w7-autosplit.txt`](../data/w7/w7-autosplit.txt). Builds
on [`w5-scaling.md`](w5-scaling.md) (why the split is needed) and
[`w4-compile-side.md`](w4-compile-side.md) (Apple already compiles the edited
file against prebuilt `.swiftmodule`s).

## S4 — access-level matrix (the load-bearing result)

| declaration access | plain `import` | `@testable import` (+ `-enable-testing`) |
|---------------------|----------------|------------------------------------------|
| `open` / `public`   | reachable | reachable |
| `package`           | reachable\* | reachable\* |
| `internal`          | **not** reachable | **reachable** |
| `private`           | not reachable | not reachable |
| `fileprivate`       | not reachable | not reachable |
| `@_spi(X) public`   | not reachable | reachable via `@_spi(X) import` |

\* `package` needs the editable unit compiled with the same `-package-name`.
Internal property wrappers and custom operators also survive the boundary via
`@testable`. `@testable` requires the stable module built `-enable-testing`
(else: *"module was not compiled for testing"*); previews build Debug, so free.

## S1 — visibility POC

An `internal struct InternalView: View` in the stable module is referenced from
a separate unit via `@testable import` and compiles. This is the typical preview
case, so the most common split target works.

## S3 — flatness (the payoff)

| stable N | bulk build once (s) | preview edit relink (s) |
|----------|---------------------|-------------------------|
| 200  | 13.2 | 0.140 |
| 1000 | 83.4 | 0.136 |

Per-edit relink is flat ~0.14 s independent of stable-module size, using the
realistic `@testable`+`internal` path. The bulk `.swiftmodule` is built once per
session and is not paid per edit. This removes the same-module scaling ceiling
W5 measured.

## S2 — symbol override (established by the spike)

JIT-link symbol override is already proven by the witness POC
(`research/jit-poc`: `host_witness.cpp`, `conform_v1/v2.swift`, `run-witness`
logs): a JIT'd object overrides a prior function and protocol-witness definition
with the base module loaded — exactly S2's requirement. Full per-pattern override
(TLVs, async, generic metadata) had partial Phase-1/2 coverage and is not
re-derived here.

## Edit kinds that break the split

1. **Preview touches `private`/`fileprivate` bulk decls** — invisible across the
   boundary at any import level. Fix: promote to `internal`, or keep that decl
   inside the editable unit.
2. **Preview touches `@_spi(X)` decls** — needs a generated matching
   `@_spi(X) import`, not a plain import.
3. **Editing the stable module's own interface** (a bulk decl, not the preview)
   — re-emits the `.swiftmodule`, so it falls back to W5 same-module cost (grows
   with N) and relinks `1 + K` objects. The split only keeps *preview-side* edits
   flat.
4. **`package` decls** — require a shared `-package-name` across the boundary.

## JIT budget framing (carrying W5 fan-out)

- **Preview-side body edit** — 1 object, ~0.14 s, flat in module size. The hot
  path the executor optimizes.
- **Preview-side edit hitting K dependents inside the editable unit** — `1 + K`
  objects; but the editable unit is small, so K is small.
- **Bulk-side / cross-boundary interface edit** — re-emit the stable
  `.swiftmodule` (W5 same-module cost, grows with N) + relink. Not the hot path;
  rare if the user is editing the view, not the library.

## Feasibility conclusion for the JIT plan

Auto-split is the production path to module-size-independent reload, and it is
viable today with `@testable import` + `-enable-testing` on a non-resilient
stable module. The executor should: build the stable module once per session
(`-enable-testing`, non-resilient), place the edited preview file in the
editable unit, `@testable import` the stable module, and JIT-link the recompiled
preview object (S2). Bounded by the four break cases above — the dominant one
being `private`/`fileprivate` references, which need promotion or co-location.

## Integrated POC — split → @testable compile → JIT-link → pixels (DONE)

The full chain now runs end-to-end on this branch
(`research/jit-poc/build-split.sh`, host `src/host_split.cpp`, run log
`research/jit-poc/data/run-split-20260604T023555Z.log`):

1. Stable module `libStable.dylib` + `Stable.swiftmodule` built
   `-enable-testing`, holding an **internal** `StableView`.
2. Editable unit (`split_preview_v1/v2.swift`): `@testable import Stable`,
   single-file compile against the prebuilt `.swiftmodule`; an
   `@_cdecl` entry renders via `ImageRenderer` and returns pixel (0,0).
3. Agent stand-in: LLJIT + ObjectLinkingLayer + `ObjCSelrefPlugin` +
   `ExecutorNativePlatform` (the host_objc.cpp stack). dlopens libStable
   (RTLD_GLOBAL), JIT-links each preview generation into a fresh JITDylib.
4. **PASS:** v1 renders red `0xFF0000`, the edited v2 renders blue `0x0000FF` —
   pixels differ across the edit, with the JIT'd code instantiating the stable
   module's internal view. S2 is now proven end-to-end, not just cited.

| stage | cold (first generation) | warm (next generation, same process) |
|-------|-------------------------|---------------------------------------|
| JIT-link (add+lookup+initialize) | 5.7 ms | **0.7 ms** |
| render | 66.5 ms | **1.1 ms** |
| dlopen stable | 110 ms (once) | — |

Edit→pixels wall-clock (3 reps): **~233 ms with respawn semantics**
(compile ~165 ms + spawn/dlopen/link/render ~69 ms). A **persistent agent**
re-linking into a fresh JD pays ~2 ms after compile → **~167 ms edit→pixels,
under the 200 ms budget**. Respawn-per-edit (Apple's model) costs the extra
~70 ms of process+dlopen warmup.

Implementation finding: the agent MUST call `LLJIT::initialize(JD)` per
generation — it runs the platform's `jit_dlopen`, registering the object's
`__swift5_*` metadata sections with the Swift runtime. Without it, SwiftUI's
runtime conformance lookups segfault in the JIT'd code (first crash we hit).
The `ObjCSelrefPlugin` + `ExecutorNativePlatform` stack from the jit-poc is
also required (SwiftUI is selref-heavy).

### Generation soak — persistent-agent viability (500 generations)

Risk probed: Swift has no deregistration for `__swift5_proto`/`__swift5_types`,
so each generation's `initialize(JD)` permanently grows the runtime registries.
Soak: one persistent host, 500 generations (fresh JD each, alternating v1/v2),
per-generation latency + RSS every 50
(`research/jit-poc/data/run-soak-20260604T024308Z.log`):

| metric | result |
|--------|--------|
| link median | flat, ~0.37–0.47 ms across all 500 |
| render median | flat, ~0.33–0.43 ms across all 500 |
| RSS | 57.9 → 101.5 MB, **~8.7 MB per 100 generations**, linear |
| mprotect/MAP_JIT failures | none |
| wrong-pixel generations | none |

Latency does NOT creep — conformance scans stay flat to 500 registered
generations. RSS grows linearly (~87 KB/generation: JIT'd object memory +
registered metadata, both unreclaimable — JD removal would free memory but
cannot deregister Swift metadata, leaving dangling registry pointers, so
freeing is unsafe). Against the adoption rule (<1 MB per 100 generations) the
RSS growth FAILS by ~9×. The flat latency, however, makes a **generation cap +
periodic background respawn** workable: respawning every ~100 edits costs one
~70 ms warmup per 100 edits (~0.7 ms/edit amortized) and caps RSS at ~+9 MB.
Trade-off: capped-persistent ≈167 ms/edit vs respawn-per-edit ≈233 ms/edit.

### private/fileprivate frequency — first read

Two-part answer. By language rule, `private`/`fileprivate` cannot be referenced
across files at all, so at **file granularity** (the split moves the whole
edited file) break-case 1 is impossible *by construction* — a moved file's
private decls move with it. Empirically: across every preview-bearing file in
`examples/` (10+ files with `#Preview` across 4 build systems), there are
**zero** private/fileprivate decls. Break-case 1 only applies to sub-file
splits (e.g. extracting just the `#Preview` block), which the executor can
avoid by always splitting at file granularity. Small sample; a wider OSS survey
would firm this up.

## What this does NOT close

- The `examples/` survey is a small sample; a wider OSS survey of real preview
  files would firm up the (so far empty) break-case-1 frequency.
- Macro-expanded code and resilience corner cases were only spot-probed.
- The POC measures a 1-file stable module; combined with S3/W5-M3 flatness the
  numbers hold as the stable module grows, but a scaled integrated run was not
  repeated here.
- Xcode 26.2 / swiftc only.

## Provenance

`/tmp/w7` probes, 2026-06-02, swiftc from Xcode 26.2 (17C52). Numbers in
[`../data/w7/w7-autosplit.txt`](../data/w7/w7-autosplit.txt).

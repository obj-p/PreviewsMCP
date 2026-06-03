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

## What this does NOT close

- Real targets may reference `private`/`fileprivate` more than expected; the
  *frequency* of break-case 1 in real code is unmeasured (a survey of real
  SwiftUI previews would size it).
- S2 was cited, not re-run end-to-end through the auto-split path; an integrated
  POC (split → `@testable` compile → JIT-link → render) is the natural next step.
- Macro-expanded code and resilience corner cases were only spot-probed.
- Xcode 26.2 / swiftc only.

## Provenance

`/tmp/w7` probes, 2026-06-02, swiftc from Xcode 26.2 (17C52). Numbers in
[`../data/w7/w7-autosplit.txt`](../data/w7/w7-autosplit.txt).

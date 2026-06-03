# W5 — Same-module scaling curve + dependency fan-out

**Status:** CLOSED (2026-06-02). Verdict: **the stable-module / thunk split is
MANDATORY at scale.** Same-module incremental recompiles 1 object but pays
whole-module front-end cost (~45 ms + 6 ms/file), breaking the 200 ms budget at
~25 files; a split holds per-edit latency flat (~140 ms) to ≥1000 files. Fan-out:
1 object for a body edit, 1+K for an interface edit touching K dependents. See
[`../../analysis/w5-scaling.md`](../../analysis/w5-scaling.md) and raw
[`w5-scaling.txt`](w5-scaling.txt).

## The question

W4 proved Apple recompiles **one file** per edit, but on an engineered target of
60 **independent** files (blast radius forced to 1). Two things it punted decide
whether single-file incremental is actually fast at scale:

1. How does same-module incremental compile time scale with module size (100 →
   1000 files) for a one-file edit?
2. What is the dependency fan-out when the edit changes a **public/internal
   declaration that other files reference**?

This is the load-bearing open question for the JIT plan's G1
(`docs/jit-executor-phase3-plan.md`, on the `#189` branch; mechanism mirrored at
`prompts/jit-executor-design.md`). Per the W4 refinement, a Swift module cannot
import itself, so a same-module edit re-parses and type-checks **all** files and
only re-emits the changed object. That makes per-edit cost grow with N. W5
measures the curve and the fan-out so we know where the <200ms budget breaks.

## Why it matters

If same-module incremental stays under budget to ~1000 files, path (a) "adopt
swiftc incremental" is enough. If it blows up with N, the stable-module/thunk
split (G1 path b) is **mandatory**, not optional. Fan-out decides how many
objects the JIT must relink per edit (not always one).

## Deliverable

1. `w5-scaling.txt` — raw timings + object-recompile counts.
2. `../../analysis/w5-scaling.md` — the two tables + a one-line verdict on where
   <200ms breaks and whether the split is mandatory.
3. Update this file's status to CLOSED with the verdict.

## Measurements

- **M1 — scaling curve.** Same-module, one-file body edit, incremental rebuild
  wall-clock at N = 100, 250, 500, 1000 files. Where possible split
  parse/type-check vs codegen using `-stats-output-dir` (or
  `-driver-time-compilation`). Report the curve, not one point.
- **M2 — fan-out.** Edit a `public`/`internal` decl referenced by K other files
  (K = 1, 10, 50); count objects recompiled (mtime diff, as W4). Contrast with
  editing a body-local change (expected: 1).
- **M3 — split comparison.** Build the same view as a small **separate** module
  importing the bulk as a prebuilt `.swiftmodule`; edit one file; time it at the
  same N. Expected flat vs M1's growth. This is the direct test of G1 path b.

## Method (reuse W4 infra)

- Generate synthetic targets at each N. Unlike W4, include **realistic
  cross-references** for the fan-out target (a shared `protocol`/`struct` that K
  files use), not all-independent files.
- Persistent isolated `derivedDataPath`; cold build once, then per-edit
  incremental `xcodebuild` (or `swiftc -incremental` + a kept output-file-map).
- mtime-diff `*.o` for recompile counts (W4 Track A method). `-stats-output-dir`
  for phase timing.

## Unknowns / risks

- Synthetic files may understate real type-check cost (generics, property
  wrappers, macros). Note this; if time allows, sanity-check against one real
  open-source SwiftUI module.
- `-stats` granularity may not cleanly separate parse vs typecheck; report what
  it gives.

## Verification criteria

- A wall-clock-vs-N table for same-module (M1) and split (M3), each with ≥4
  sizes.
- A fan-out table (M2) with object counts for K = 1/10/50.
- An explicit statement: the largest N where same-module one-file edit stays
  <200ms, and whether the thunk-split is required beyond it.

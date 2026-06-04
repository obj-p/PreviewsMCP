# W7 — Auto thunk-split feasibility

**Status:** CLOSED (2026-06-02). Verdict: **FEASIBLE for the common case.** An
`internal` SwiftUI view splits into a separate unit via `@testable import` against
a stable module built `-enable-testing`, and edit→relink stays flat (~0.14 s) at
stable N=200 and 1000. Breaks when the preview references `private`/`fileprivate`
decls (invisible across the boundary). UPDATE 2026-06-04: the **integrated POC**
now proves S2 end-to-end — split → @testable compile → JIT-link → pixels PASS
(`research/jit-poc/build-split.sh`); edit→pixels ~233 ms respawn / ~167 ms
persistent-agent. See
[`../../analysis/w7-autosplit.md`](../../analysis/w7-autosplit.md) and raw
[`w7-autosplit.txt`](w7-autosplit.txt).

## The question

G1 path (b) — the only way to make reload time **independent of module size** —
is to put the editable preview in a **separate** compilation unit that imports
the bulk of the target as a prebuilt `.swiftmodule`. That turns an expensive
same-module recompile into cheap cross-module reuse (see
`../../analysis/w4-compile-side.md` and the W5 split track). The open question:

> Can we auto-split an arbitrary user target into a stable module + an editable
> preview unit **without the user restructuring their package**, given that the
> preview references the target's `internal` types?

## Why it matters

If feasible, it is the production path to sub-second reload on large modules and
removes the same-module scaling ceiling W5 measures. If not (or only with heavy
caveats), the JIT executor is bounded by same-module incremental cost and the
plan should say so.

## Subproblems + verification criteria

- **S1 — visibility.** The preview unit must see the stable module's `internal`
  declarations (SwiftUI views are usually `internal`). A normal `import` only
  sees `public`. Options: `@testable import` (exposes `internal`; needs the
  stable module built `-enable-testing`, debug-only, fine for previews), or a
  generated `public` shim. **Verify:** a preview in a separate unit references an
  `internal` type of the stable module and compiles.
- **S2 — symbol override.** JIT-linking the edited preview's symbols must win
  over any prior definition once the stable module is loaded. **Verify:** with
  the stable module loaded in the agent, the JIT'd object's symbol resolves and
  overrides (mirrors Phase 1 witness-override).
- **S3 — build wiring.** Emit the stable module's `.swiftmodule` once per
  session; recompile only the edited preview file against it. **Verify:**
  edit → single-file compile → link, wall-clock roughly flat as the stable
  module grows (ties to W5 M3).
- **S4 — access-level matrix.** Map what `@testable` reaches (`internal`) and
  what it does **not** (`private`/`fileprivate`, and `-enable-library-evolution`
  resilience effects). **Verify:** a table of access levels reachable across the
  synthetic boundary, with the edits that break.

## Method

- Start with a 2-file SwiftUI target. Split one `View` + its `#Preview` into a
  separate unit; `@testable import` the stable module; JIT-link the preview file
  via the existing `PreviewsJITLink` harness.
- Then scale the stable module (reuse W5's generator) to confirm S3 flatness.
- Build host; no VM needed (no private-framework capture here).

## Unknowns / risks

- `@testable` needs `-enable-testing` on the stable module (debug-only) — confirm
  previews always build debug.
- `private`/`fileprivate` decls referenced by the preview stay invisible; how
  often do real previews touch those? Note the failure mode.
- Property wrappers, operators, `@_spi`, and macro-expanded code may not survive
  the split cleanly. Probe a few.
- The synthetic boundary must not change runtime behavior (e.g. resilience /
  ABI). Keep the stable module non-resilient (app-internal) for previews.

## Verification criteria

- A yes/no feasibility verdict with the S4 access-level matrix.
- A working POC: an `internal`-referencing preview in a separate unit, JIT-linked
  and rendering, with edit→relink wall-clock flat across ≥2 stable-module sizes.
- A clear list of what does NOT survive the auto-split (the caveats that bound
  it).

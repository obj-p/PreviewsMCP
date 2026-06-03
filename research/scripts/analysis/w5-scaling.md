# W5 — same-module scaling curve + dependency fan-out

**Verdict: the stable-module / thunk split is MANDATORY at scale.** Same-module
incremental recompiles only one *object* per edit but pays *whole-module*
front-end cost, so per-edit latency grows ~6 ms/file and exceeds the 200 ms
budget past **~25 files**. A split (bulk as a prebuilt `.swiftmodule` + a small
editable unit) holds per-edit latency **flat at ~140 ms to at least 1000 files**.
This settles G1: path (b) is required, not optional.

Raw data: [`../data/w5/w5-scaling.txt`](../data/w5/w5-scaling.txt). Builds on
W4's single-file finding ([`w4-compile-side.md`](w4-compile-side.md)).

## Method

Raw `swiftc -c -incremental -enable-batch-mode` with a persisted
output-file-map (handoff-sanctioned; same compiler as Xcode, faster across
sizes). One-file body edit, incremental rebuild, median of 3 reps. Recompile
counts via `*.o` mtime diff (W4 Track A). **Caveat:** filler files are trivial
structs, which understate real body type-check cost — so the same-module
numbers are a *lower bound*; real SwiftUI code breaks the budget sooner.

## M1 — same-module incremental scaling

| N (files) | cold (s) | incremental (s) | objects re-emitted |
|-----------|----------|-----------------|--------------------|
| 100  | 0.69 | 0.65 | 1 |
| 250  | 1.57 | 1.41 | 1 |
| 500  | 3.13 | 2.82 | 1 |
| 1000 | 6.73 | 6.06 | 1 |

One object (`View.o`) re-emitted at every N, yet wall-clock grows ~linearly.
Incremental is ~90% of cold (1000: 6.06 vs 6.73 s), so codegen of the other 999
files costs only ~0.7 s — the ~6 s is front-end work (parse + bind **all** N
files), which a same-module edit must redo because a module cannot import
itself. Linear fit ≈ **45 ms + 6.0 ms/file**, so 200 ms breaks at **~25 files**.

## M2 — dependency fan-out (N=200, shared decl used by K files)

| K | body-local edit | interface change |
|---|-----------------|------------------|
| 1  | 1 | 2  |
| 10 | 1 | 11 |
| 50 | 1 | 51 |

A body-local change recompiles **1** object regardless of K. Changing the
*interface* of a decl that K files reference recompiles **1 + K** — the changed
file plus every dependent. So a JIT relinks one object for a body edit, but
`1 + K` for a public/internal API edit.

## M3 — split comparison (bulk prebuilt `.swiftmodule` + view module)

| N (bulk) | bulk build once (s) | view edit (s) | objects re-emitted |
|----------|---------------------|---------------|--------------------|
| 100  | 5.85  | 0.144 | 1 |
| 250  | 15.99 | 0.148 | 1 |
| 500  | 36.91 | 0.143 | 1 |
| 1000 | 95.64 | 0.145 | 1 |

Per-edit time is **flat ~0.144 s** independent of bulk size. The bulk is parsed
and bound once into a binary `.swiftmodule`; editing the view only parses the
view and loads the prebuilt module interface. The large one-time bulk build is
not paid per edit. This is the direct test of G1 path (b), and it passes.

## Implications for the JIT executor plan (G1)

- **Adopt-plain-swiftc-incremental (path a) does not scale.** It is fine for
  tiny targets but exceeds 200 ms by ~25 files and grows linearly. Real targets
  are routinely hundreds to thousands of files, so path (a) alone is a dead end.
- **The stable-module / editable-unit split (path b) is required** and is what
  keeps reload flat. This matches what Apple already does: W4 showed the preview
  thunk compiles the one edited file against prebuilt `.swiftmodule`s
  (`-disable-implicit-swift-modules` + explicit module map), i.e. the bulk is
  never re-bound per edit. W5 quantifies why that design is necessary.
- **Fan-out budgeting.** Plan for relinking `1 + K` objects on an interface
  edit, not one. Body-only edits stay at one. W7 (target auto-split) is the
  mechanism that makes this affordable; W5 is its justification.

## What this does NOT close

- Trivial synthetic bodies understate real type-check cost; a sanity check
  against one real open-source SwiftUI module is still worth doing (M1 is a
  conservative lower bound, so the verdict only strengthens).
- `-stats` per-job granularity did not give a clean parse/sema/codegen wall
  split; the inc-vs-cold inference is used instead.
- Measured on Xcode 26.2 / swiftc; not swept across toolchains.

## Provenance

`/tmp/w5` harness (`m1.sh`, `m2.sh`, `m3.sh`), 2026-06-02, swiftc from Xcode
26.2 (17C52). Full numbers in [`../data/w5/w5-scaling.txt`](../data/w5/w5-scaling.txt).

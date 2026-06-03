# W4 — Compile-side capture: does Apple recompile one file or the whole module?

**Status:** CLOSED (2026-06-02). Verdict: **ONE file, not the module** — Xcode
recompiles only the changed file against prebuilt modules, on every edit kind
swept. G1's single-file-incremental premise CONFIRMED. See
[`../../analysis/w4-compile-side.md`](../../analysis/w4-compile-side.md) and raw
capture [`w4-compile-trace.txt`](w4-compile-trace.txt). Run on the build host
(not the VM) — Xcode 26.2 toolchain is identical and the question is host-side.

## The question

W3 closed the **dispatch** side: Apple respawns `XCPreviewAgent` per edit and
never `write_mem`-patches (see [`../w3/handoff.md`](../w3/handoff.md),
[`../../analysis/w3-empirical-capture.md`](../../analysis/w3-empirical-capture.md)).
W3 never watched the **build** side. The whole hot-reload speed story rests on a
*claim we have not measured*:

> On a single SwiftUI body edit, Xcode recompiles **only the changed file**
> against a prebuilt module, not the whole module.

`prompts/jit-executor-design.md:260` states this as "incremental swiftc" and
hedges it ("appears to have only ONE path for edit dispatch"). The PreviewsMCP
JIT plan now flags it as an unverified premise (G1 in
`docs/jit-executor-phase3-plan.md`, "Recompile-narrowing gaps"). W4 confirms or
refutes it with a capture.

> Note: `docs/jit-executor-phase3-plan.md` lives on the `#189` JIT branch, not
> on `previews-research`. The same premise is quoted inline at
> `prompts/jit-executor-design.md:260` ("incremental swiftc"), which IS present
> here, so use that as the on-branch source.

## Why it matters

If true, our JIT executor must add single-file incremental compile against a
prebuilt `.swiftmodule` (plan gaps G1+G2) to hit the <200ms target. If false
(Apple full-recompiles too), the latency win lives somewhere else and the JIT
plan's compile assumptions need rethinking. Either result is load-bearing.

## Deliverable

1. `w4-compile-trace.txt` — the raw capture of build-host process activity
   during exactly one body edit (see method).
2. `../../analysis/w4-compile-side.md` — analysis note answering the three
   measurements below, mirroring `w3-empirical-capture.md` in shape.
3. Update this file's status to CLOSED with a one-line verdict + pointer.

## Measurements (the answer is these three numbers)

- **M1 — invocation count.** How many `swift-frontend` (and/or `swiftc`)
  processes spawn for one body-literal edit? One? One-per-file?
- **M2 — input scope.** For each invocation, the list of `-primary-file` /
  input `.swift` paths. Is it one file, or all target files? Is a prebuilt
  `.swiftmodule` passed in (`-I` / explicit module input / `.swiftmodule`
  on the command line)?
- **M3 — wall-clock.** Time from save to first new render, split into
  compile vs respawn if separable.

## Method (reuse W3 infra)

- **Environment.** Same VM kit as W3 (`research/vm/`; see auto-memory
  `project_vm_*` and `reference_jit_poc_artifacts`). Restore the `post-ssh` or
  `post-sa` snapshot, Xcode installed, a multi-file SwiftUI target open with a
  `#Preview`. A ≥50-file target makes whole-vs-one obvious.
- **Capture (pick the lightest that works):**
  - `fs_usage -w -f exec` filtered to `swift-frontend`/`swiftc` while you make
    one edit. Cheapest. Gives exec args (M1, M2).
  - `dtrace` `proc:::exec-success` on the build host (pattern of W3's
    `capture-write-mem.d`) if `fs_usage` arg capture is truncated.
  - As a cross-check, `sample` or `ps` the build pipeline; Xcode's build log
    (`~/Library/Developer/Xcode/DerivedData/*/Logs/Build`) records the actual
    frontend command lines per compile — often the easiest M2 source.
- **Protocol.** Cold-open the preview once (ignore that build). Then change a
  single literal in a `View` body, save, capture until the new render appears.
  Repeat 3 times for stability. Then do a **structural** edit (add a method) and
  a **graph** edit (add a new file) to see if scope changes by edit kind, the
  same axis W3 swept.

## Unknowns / risks

- Xcode may route preview builds through `XCBBuildService` with its own
  incremental engine, so the `swift-frontend` command may differ from a plain
  `swiftc` build. Capture what actually runs, not what we expect.
- Build-log command lines may show `-whole-module-optimization` off but still
  list all files with `-primary-file <one>`. That IS single-file incremental
  (batch mode, one primary). Read the flag semantics, do not just count paths.
- The VM Xcode-driving path was flaky in W3 (`../w3/xcode-driving-attempt.md`).
  If GUI driving blocks, a manual edit with capture running is acceptable; the
  measurement is the build commands, not the automation.

## Verification criteria (how we know W4 is done)

- M1, M2, M3 each have a concrete recorded value for a body-literal edit.
- The `-primary-file` vs full-input question is answered with a quoted command
  line, not an inference.
- The verdict states whether plan gap G1's premise (single-file recompile)
  holds, and notes any edit-kind where it does not.

# W6 — Canvas thunk-compile argv + design-time literal injection

**Status:** CLOSED (2026-06-04). M1 thunk argv was captured live on the host in
W4 (no VM needed) — single `-primary-file` + `-vfsoverlay` + explicit module map,
NO filelist/incremental. M2 design-time lifecycle modeled: generate `#salt_n`
IDs → `@Observable` store keyed by ID → re-inject via `PreviewsInjection`
`EntryPoint` `UpdatePayload` over XPC, no recompile. M3 boundary = skeleton-equal
+ literal-only + SwiftUI region → injection; else (skeleton change OR UIKit-region
literal) → recompile. See
[`../../analysis/w6-designtime.md`](../../analysis/w6-designtime.md) and
[`w6-canvas-argv.txt`](w6-canvas-argv.txt).

## The question

Two things W4 left open about the **canvas hot-reload path** (the one users feel,
which does NOT route through `xcodebuild`/Logs/Build):

1. What is the exact `swift-frontend` command line for a **preview-thunk**
   compile? W4 had only the on-disk artifacts (thunk source + VFS overlay), not
   the argv, because SIP blocked dtrace on the build host.
2. How does Apple's **design-time literal injection** work end to end?
   `__designTimeString`/`Integer`/`Float`/`Boolean(_:fallback:)` let a
   literal-only edit refresh the preview with **no recompile**. We want the
   runtime mechanism, not just the generated call sites.

## Why it matters

- The thunk argv tells us whether the canvas uses full-filelist + `-incremental`
  (like the build-system path) or something narrower per edit. It refines G1's
  same-module cost estimate (W5) with Apple's real fast-path numbers.
- The injection mechanism is the bigger prize: if we mirror it, a **literal-only
  edit needs no compile and no respawn at all**, the same idea as this project's
  `DesignTimeStore`. Understanding Apple's ID scheme + runtime delivery tells us
  how far to push our literal path before falling back to JIT.

## Deliverable

1. `w6-canvas-argv.txt` — the captured `swift-frontend` argv for a thunk compile.
2. `../../analysis/w6-designtime.md` — a written model of the design-time ID
   lifecycle (generate → store → re-inject at runtime) + the literal-vs-
   structural boundary.
3. Update this file's status to CLOSED.

## Measurements

- **M1 — thunk argv.** The full `swift-frontend` invocation for a
  `*.preview-thunk.swift` compile during a live canvas edit. Confirm whether the
  VFS overlay + full filelist + `-incremental` are present.
- **M2 — injection mechanism.** How `#7210_0`-style IDs are generated and keyed;
  what runtime API reads them; how a new literal value reaches a running preview
  without recompiling (look at the `PreviewsInjection` EntryPoint family — exports
  already captured in `../w3/PreviewsInjection-exports.txt` — and the
  `__designTime*` symbols in SwiftUI: `nm`/`strings`).
- **M3 — edit-kind boundary.** Which edits qualify for injection-only (pure
  literal) vs force a thunk recompile (structural). Sweep a few.

## Method

- **Capture the argv.** `fs_usage -w -f exec` may be limited under SIP on the
  build host; the clean path is the **W3 VM with SIP disabled** (`post-sip`
  snapshot — see auto-memory `project_vm_recovery_automation_tahoe`), where
  `dtrace`/`proc:::exec-success` (pattern of `../w3/capture-write-mem.d`) can
  grab the thunk frontend argv during a driven canvas edit.
- **Injection.** Static: disassemble/inspect `__designTimeString` &c. in SwiftUI
  and the `PreviewsInjection` framework (reuse W3's dumped exports). Dynamic: if
  the VM canvas can be driven, watch what gets sent to the agent on a literal
  edit (W3 showed `run_program_*` only fire on render — see whether literal edits
  add a value-injection verb or reuse the same path with new fallback data).

## Unknowns / risks

- The preview build service may spawn the frontend so `fs_usage` sees it only
  partially; prefer the SIP-off VM + dtrace.
- Canvas GUI driving was flaky in W3 (`../w3/xcode-driving-attempt.md`). A manual
  edit with capture running is acceptable; the argv + artifacts are the evidence.

## Verification criteria

- A quoted thunk `swift-frontend` argv (M1), not reconstructed.
- A written design-time ID lifecycle (M2): where IDs come from, what runtime call
  consumes them, how a value updates live.
- The literal-vs-structural boundary stated with the edits that were swept (M3).

# JIT compile-strategy research arc — index (W4-W7, CLOSED)

One research arc, June 2026: what compilation strategy must feed the JIT
executor so hot-reload is fast at module scale? All items CLOSED. The consuming
document is `docs/jit-executor-phase3-plan.md` on branch
`jit-phase3-session-integration` (issue #189, PR #190) — see its
"Recompile-narrowing gaps" and "Key decision" sections for how these verdicts
were folded into the plan.

## Verdicts (reading order)

1. **W4 — Apple recompiles ONE file per edit.**
   [`w4-compile-side.md`](w4-compile-side.md). Object-mtime diff (1 of 61) plus
   a live capture of the preview thunk `swift-frontend` argv: single
   `-primary-file`, `-vfsoverlay` thunk substitution, prebuilt-module reuse via
   explicit module map. Also: previews on Xcode 26.x use PreviewRegistry-reentry
   + respawn, NOT Swift dynamic replacement.
2. **W5 — same-module incremental does not scale; the split is MANDATORY.**
   [`w5-scaling.md`](w5-scaling.md). Whole-module front-end costs ~45ms +
   6ms/file per edit (200ms budget breaks ~25 files); a stable-module/editable-
   unit split stays flat ~0.14s to 1000 files. Fan-out: 1 object per body edit,
   1+K per interface edit.
3. **W7 — the split is FEASIBLE for the common case.**
   [`w7-autosplit.md`](w7-autosplit.md). `internal` view in a separate unit via
   `@testable import` against a `-enable-testing` stable module; always split at
   file granularity. Integrated POC (`../../jit-poc/build-split.sh`) proves
   split → `@testable` compile → JIT-link → render end-to-end (~233ms respawn,
   ~167ms persistent). Generation soak (500 gens): latency flat, RSS leaks
   ~87KB/gen → executor shape = **capped-persistent, respawn every ~100 edits**.
4. **W6 — Apple's literal fast-path is data injection; three-tier model.**
   [`w6-designtime.md`](w6-designtime.md). Canvas thunk compile is already the
   split shape (no filelist/incremental). Literal edits re-inject by
   `#salt_n` ID via `PreviewsInjection` `UpdatePayload`, no recompile/respawn;
   structural edits JIT-link. Tier boundary = `LiteralDiffer` skeleton-equality.

## Raw data

`../data/w4/` (thunk argv, compile traces), `../data/w5/` (scaling),
`../data/w6/` (canvas argv), `../data/w7/` (autosplit, soak log under
`../../jit-poc/data/`). Each `data/w*/handoff.md` is CLOSED-stamped with its
verdict. Dispatch-side companion (W3, respawn-only): `w3-empirical-capture.md`.

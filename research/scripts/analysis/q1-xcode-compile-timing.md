# Q1/Q3/Q4/Q5 — Xcode Previews per-edit process timing (in-VM dtrace)

**Verdict: Xcode Previews does NOT avoid the fixed `swift-frontend` cost.** It
spawns a **fresh** `swift-frontend` per edit (no persistent compiler, no warm
process, no CAS/`-cache-compile-job` evidence) and **respawns `XCPreviewAgent`
every edit**. For structural edits it eats a full compile + respawn of
**~1.5-2.5 s save→agent-respawn**, which is *slower* than our agent-JIT
structural path (~816 ms), not faster. The sub-200 ms "feel" Xcode gives is the
**literal-injection fast path** (W6 `__designTimeString`), not these structural
recompiles. So for the sharpened Q1 the answer is: **they simply eat a similar
~300 ms compile** — they do not dodge it.

Captured live with `dtrace proc:::exec-success / proc:::exit` inside the research
VM (SIP off unlocks the proc provider), driving real Xcode 26.2 Previews on a
2-file SwiftUI package through the 12-edit matrix. Each edit is anchored by a
`logger "W3MARKER eN"` exec in the same `walltimestamp` clock. Raw trace:
[`../data/q1-dtrace-capture/q1-dtrace.txt`](../data/q1-dtrace-capture/q1-dtrace.txt)
(267 lines, 12 edits).

## Per-edit numbers

| edit | kind | swift-frontend procs | swift-driver | longest FE | save→agent-respawn |
|------|------|---------------------|--------------|-----------|--------------------|
| e1 | body-literal same-file | 3 | 0 | 352 ms | 2504 ms |
| e2 | body-literal cross-file | 4 | 0 | 289 ms | 2060 ms |
| e3 | add-method | 3 | 0 | 155 ms | 2018 ms |
| e4 | add-state | 3 | 0 | 142 ms | 1871 ms |
| e5 | remove-stored-property | 3 | 0 | 135 ms | 2067 ms |
| e6 | function-sig change | 3 | 0 | 148 ms | 1119 ms |
| **e7** | **new-file + new-type** | **12** | **3** | **1117 ms** | **3849 ms** |
| e8 | conformance addition | 4 | 0 | 147 ms | 1697 ms |
| e9 | whitespace-only | 3 | 0 | 152 ms | 1534 ms |
| e10 | generic-parameter add | 3 | 0 | 151 ms | 1514 ms |
| e11 | simultaneous two-file | 4 | 0 | 151 ms | 451 ms* |
| e12 | touch no-change | 2 | 1 | — | — |

\* e11/e12 windows overlap (rapid back-to-back), so their split is approximate.

## What the trace shows

1. **Fresh compiler per edit — no persistence.** Every edit spawns brand-new
   `swift-frontend` PIDs (34 under ppid 1015, 11 under ppid 966, 2 under 993
   across the run). There is no long-lived compiler reused across edits. This
   matches our own per-edit `swift-frontend` and kills the "persistent compiler"
   hypothesis.

2. **No swift-driver for body/structural edits; driver only for new-file.**
   Edits e1-e6, e8-e10 invoke `swift-frontend` **directly** (parent = the build
   arena), no `swift-driver` — exactly the canvas thunk shape from W4. Only the
   new-file (e7), two-file (e11) and touch (e12) edits invoke `swift-driver`.
   So Apple bypasses the driver for the common edit, same target we identified.

3. **Per-edit frontend lifetime ~135-352 ms.** The steady-state structural edits
   cost ~140-155 ms of `swift-frontend` (longest child); the first edit is 352 ms
   (cold). This brackets the investigator's ~350 ms local number. No flag or
   process trick shrinks it — Apple pays it.

4. **Two compile arenas (Q3 delivery shape).** Two distinct parents spawn the
   compilers each edit: **ppid 1015** (the bulk: 2-3 `swift-frontend` + `clang`
   + `ld`) then **ppid 966** (1 `swift-frontend` + `clang`) firing right before
   the agent respawn. Read as: build-arena compiles the thunk/module, the
   previews arena produces the final object, then `XCPreviewAgent` re-execs and
   renders. Materialization is the agent re-exec + its post-exec render.

5. **Respawn-per-edit confirmed (Q5).** 12 distinct `XCPreviewAgent` PIDs, one
   per edit; each old agent EXITs then a new one EXECs with ppid=1 (posix_spawn,
   reparented to launchd). Reconfirms W3 respawn-only, now from the compile/spawn
   side on a clean run.

6. **Save→pixels is NOT sub-200 ms for structural edits (Q4).** save→agent-
   respawn is ~1.5-2.5 s for normal structural edits and ~3.8 s for the new-file
   edit. Render adds a little more (untraced). This is well above the 200 ms
   target and above our ~816 ms structural number — Xcode is not magically fast
   here. The fast class is literal injection (W6), which recompiles nothing.

## Caveats

- `pr_psargs` came back as execname only (no argv flags), so the per-edit
  `-primary-file` flags are **not** re-confirmed in-VM. The full argv is already
  the host W4 capture (`../data/w4/w4-thunk-argv.txt`); this run adds **timing +
  process structure**, not flags.
- The `save→first-frontend` gap (~0.5-1.6 s) is inflated by editing via `sed`
  (a file-change event Xcode's file-watcher debounces) rather than typing into
  the editor buffer. The robust numbers are the **frontend lifetime** (~140-350
  ms) and the **respawn** structure, not the detection latency.
- Xcode 26.2 / macOS 26.3.1, 2-file package, single canvas. Not swept across
  package sizes (that is W5's domain) or Xcode versions.

## How it was captured

`research/scripts/provision-and-capture.sh` (resumable pipeline) → the
`drive-xcode-preview` preset's dtrace path. Snapshot `post-xcode-ready`
(Xcode first-launch baked in via `xcodebuild -runFirstLaunch`) is the restore
point. The tracer starts **after** `AGENT_UP` (started before canvas-open its
per-exec overhead pushed the agent past previewsd's spawn window). VM bundle:
`~/.previews-research-vms/research.bundle`.

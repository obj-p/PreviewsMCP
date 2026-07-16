# research/

Non-shipping experiments behind product decisions. Nothing here is built by
Bazel or `Package.swift`, and `research/` is excluded from the lint sweep
(`tools/lint/lint.sh`). Compiled artifacts are never committed — every
experiment rebuilds from source when run.

The point of keeping experiments here (instead of in a findings doc alone) is
**drift detection**: our product rests on reverse-engineered and empirical
claims about Xcode, swiftc, LLVM, and macOS. Each new Xcode or macOS major
(Xcode 27, macOS next) can silently invalidate them. A committed experiment
turns "is that still true?" into a command that answers green or red.

## Layout

One experiment = one directory = one claim, with a journal (`README.md`) that
follows this template:

```markdown
# <name> — <one-line claim>

**Question.** The single hypothesis this experiment tests.

**Environment.** What it needs: host tier (VM-free) or vzy snapshot
(`post-xcode`, `post-xcode-sip-amfi`, …); toolchain requirements; the
Xcode/macOS versions it last ran against.

**Run.** The exact command, ideally just `./reproduce.sh`. What green looks
like, what red means.

**Result.** What happened, with the asserted output or committed fingerprint.

**Conclusion.** What the result proves and which product decision, design doc,
or issue it feeds.

**Status.** `reproduction (green as of <date>, Xcode <ver> / macOS <ver>)`
or `capture (frozen, taken on Xcode <ver> / macOS <ver>)`.
```

## Two tiers

- **Reproduction** — the normal case. A `reproduce.sh` (or `run.sh`) rebuilds
  the experiment from source, re-runs it, and asserts the result against a
  committed expectation (output marker or fingerprint file). Green means the
  claim still holds on the current toolchain; red means drift, which is the
  signal we want. VM-dependent reproductions boot the snapshot they need via
  [vzy](https://github.com/obj-p/vzy).
- **Capture** — the exception, for one-off empirical data that is too costly
  or too environment-bound to re-run (dtrace traces, symbol dumps, timing
  runs). A capture commits the raw data next to its analysis writeup and is
  explicitly marked frozen, with the environment it was taken in. A capture
  makes no claim about current toolchains.

Prefer a reproduction wherever one is affordable. A capture that later proves
load-bearing is a candidate to be redone as a reproduction.

## Current experiments

| Path | Tier | Claim |
|---|---|---|
| [`jit-poc/`](jit-poc/) | reproduction (host) | Public LLVM ORC/JITLink + `swiftc -emit-object` can hot-swap every hard Swift emission pattern — the same architecture Apple's `XOJITExecutor` uses. |
| [`previews-re/`](previews-re/) | reproductions (VM) | Xcode-Previews RE findings, one `finding-*/` per claim, each restoring the vzy snapshot it needs. |

## Migrating the research branches

`previews-research`, `previews-research-3201`, and `archive/*` hold the
original spike-era material (VM harness, dtrace captures, analysis docs,
#254 spikes). Policy:

- **Do not bulk-copy.** The branches are source material, not content. Most of
  it is superseded (`research/vm` → vzy) or raw data whose question is better
  re-asked than re-imported.
- **Redo, don't rescue.** Migrate a finding by re-running it against the
  current toolchain and landing it as a reproduction under the template.
  Original context may be lost; validated current context is gained.
- **Restart from what is committed.** `jit-poc/` and `previews-re/` are the
  base. New experiments land beside them; the branches are only consulted for
  what a finding claimed and how it was originally demonstrated.
- **Select by leverage.** Migrate a finding only when it still backs a live
  product decision or an open issue. Everything else stays on the archived
  branches, which remain readable history.

## Re-experiment cadence

On each Xcode or macOS major (and any toolchain pin bump), re-run every
reproduction. Red is not a chore, it is the finding: file what drifted before
touching product code that depends on the claim.

# research/

Experiments that guide the architecture of PreviewsMCP. Each experiment
validates a claim about Xcode, swiftc, LLVM, or macOS that an architectural
decision rests on, and stays re-runnable so the claim can be re-checked when
the toolchain moves (a new Xcode or macOS major). Non-shipping: nothing here
is built by Bazel or `Package.swift`, `research/` is excluded from the lint
sweep, and compiled artifacts are never committed.

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
  claim still holds on the current toolchain; red means drift. VM-dependent
  reproductions boot the snapshot they need via
  [vzy](https://github.com/obj-p/vzy).
- **Capture** — the exception, for one-off empirical data that is too costly
  or too environment-bound to re-run (dtrace traces, symbol dumps, timing
  runs). A capture commits the raw data next to its analysis writeup and is
  explicitly marked frozen, with the environment it was taken in. A capture
  makes no claim about current toolchains.

Prefer a reproduction wherever one is affordable. A capture that later proves
load-bearing is a candidate to be redone as a reproduction.

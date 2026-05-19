# research/scripts/

Python and shell harnesses for the JIT-executor research spike
(`prompts/jit-executor-research.md`). All scripts run **from the
host** and invoke things **inside the research VM** via
`previewsvm ssh`.

## Prerequisites

A bundle that has reached the `post-xcode-sip-amfi` snapshot — see
`research/vm/PROGRESS.md` for the pipeline that produces it. The
scripts here assume:
- the bundle path is in `$PREVIEWSVM_BUNDLE` (default `/tmp/verify.bundle`)
- `previewsvm` is built and on `$PATH` (or available at
  `research/vm/.build/release/previewsvm`)
- the VM is **booted** (`previewsvm boot $PREVIEWSVM_BUNDLE
  --skip-ssh-wait &`) before running anything that talks to the guest

A typical research session looks like:

```bash
cd research/vm
.build/release/previewsvm snapshot restore /tmp/verify.bundle post-xcode-sip-amfi
.build/release/previewsvm boot /tmp/verify.bundle --skip-ssh-wait &
# (wait for SSH to come up)
cd ../scripts
./dump-previews-pipeline-exports.sh > data/previews-pipeline-exports.txt
```

## Scripts

| Script | What it does | Spike learning-target |
|---|---|---|
| `dump-previews-pipeline-exports.sh` | Lists every exported symbol of `Xcode.app/Contents/SharedFrameworks/PreviewsPipeline.framework`, swift-demangled, sorted | LT-1 / W2 — pipeline step decomposition (`docs/reverse-engineering.md:569-577`) |

Outputs land in `data/` and are checked in — they're the empirical
basis for the findings doc (`prompts/jit-executor-findings.md`).

## Conventions

- Scripts are idempotent — re-running overwrites the output file.
- Standard output is the data; status / progress goes to stderr.
- Exit non-zero on any failure that would make the data incomplete
  or misleading; never silently truncate.
- VM-side commands prefer `xcrun` over hardcoded toolchain paths,
  so the script keeps working when we bump the Xcode version in the
  base snapshot.

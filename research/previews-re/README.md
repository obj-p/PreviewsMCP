# research/previews-re — Xcode-Previews RE reproductions (vzy)

VM-dependent reproductions of the Xcode-Previews reverse-engineering findings.
Each `finding-*/reproduce.sh` boots a baked macOS VM (via `vzy`) in the state
the finding needs, re-runs the experiment, and asserts the result against a
committed fingerprint. Green = the finding still holds on the guest's
macOS/Xcode; red = drift. Source of the original findings:
`archive/previews-research-3201`.

Prerequisite: a baked vz bundle (see the bake ladder). None of these run until
`install → post-sa → post-sip → post-amfi → post-xcode` has produced the
snapshot each finding restores.

| Finding | Snapshot | Drive | Status |
|---|---|---|---|
| `finding-1-orc-is-llvm-jitlink` | post-xcode | SSH-only | skeleton staged (assert XOJITExecutor exports the LLVM-ORC/JITLink symbol set) |
| finding-2 app-target PID census | post-xcode-ready | VNC drive | pending (needs ported drive-xcode-preview preset) |
| finding-3 recompile-one-file | post-xcode-ready | VNC drive | pending |
| finding-4 write-mem dtrace (flagship) | post-xcode-sip-amfi | VNC + dtrace | pending (spike; completes an open capture) |
| finding-5 per-edit latency | post-xcode-ready | VNC + timing | pending |

The host-tier (VM-free) LLVM-ORC/JITLink reproduction lives separately at
`research/jit-poc` — it proves the *same architecture* is reachable on public
LLVM, and needs no VM.

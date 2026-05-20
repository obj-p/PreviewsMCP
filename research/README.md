# research/

Throwaway research code for the JIT-executor spike scoped in
[`prompts/jit-executor-research.md`](../prompts/jit-executor-research.md).

> **Non-shipping.** Nothing in `research/` is built by the main `Package.swift`
> or shipped in `previewsmcp`. The contents here are validation harnesses,
> dtrace/lldb scaffolding, and exploratory POCs. The only output that outlives
> the spike is the findings doc (`prompts/jit-executor-findings.md`) and an
> optional design doc.

## Subdirectories

| Path | Workstream | What it is |
|---|---|---|
| [`vm/`](vm/) | W1 | Swift CLI wrapping `Virtualization.framework` — the harness for spinning up a SIP+AMFI-off macOS VM and connecting to it for dtrace/lldb work. |
| `scripts/` | W1 (planned) | Python wrappers for the dtrace/lldb workflows once a debuggable VM is reachable. Not present yet — depends on `vm/`. |
| `jitlink/` | W2 (planned) | Minimal `llvm-jitlink`-driven harness that loads a Swift `.o` and demonstrates a function override. Not present yet — depends on `vm/`. |

## Done-when for the spike

The spike exits when `prompts/jit-executor-findings.md` is written. See the
research doc for the full exit criteria.

## Why a separate package

`research/vm/` is its own Swift package (not a target in the root
`Package.swift`) for three reasons:

1. **Entitlement requirements differ.** `Virtualization.framework` needs
   `com.apple.security.virtualization` and SPM's main package shouldn't carry
   that entitlement.
2. **Throwaway code.** Keeping it isolated means a `rm -rf research/` cleanup
   at the end of the spike has zero blast radius on the shipping product.
3. **Different build cadence.** Research binaries get rebuilt+codesigned via
   their own `build.sh`; they don't need to share the main package's plugin
   build graph.

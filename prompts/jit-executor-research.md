# JIT Executor Research

Scope document for the research effort tracked in `thunk-architecture.md`'s "Future direction" section
and `README.md`'s open follow-ups ("JIT executor research direction"). This is a **research scope**,
not an implementation plan — the deliverable is a decision document, not a shipping feature.

## Framing

We are **not** planning to ride on Apple's preview stack (`XCPreviewAgent`, `PreviewsPipeline`,
`HostAgentSystem`, OOPJit page format). Doing so would couple us to private wire protocols and
private build-artifact formats that shift per Xcode release, and Apple's licensing posture toward
their preview frameworks is "internal-only" by default.

Instead, the goal is to **understand the architectural shape Apple uses, then build a similar stack
of our own** on top of stable public layers — LLVM JITLink/ORC, `swiftc -emit-object`, Mach-O loader
semantics, and the public JIT entitlement. Apple's internals are a *reference design*, not a
*dependency*. The research-mode dtrace/lldb work exists to extract the *design decisions* Apple made
(which symbols to patch, how the agent's lifecycle is structured, how override semantics propagate
through Swift vtables / witness tables), not to consume Apple's artifacts.

## Product target

PreviewsMCP targets full Xcode Previews replacement at any scale — small SwiftUI examples through
1000+ file production modules — and explicitly includes agentic workflows (LLM-driven
edit / render / evaluate loops, many concurrent sessions). This frames what "works" means for the
research below and informs why the thunk architecture in `thunk-architecture.md` is treated as a
small-module holdover rather than the path to the product:

- **Large modules.** Thunk relies on `-enable-implicit-dynamic` to make every function in the
  stable build replaceable. At production scale that becomes pervasive call indirection across the
  entire module, breaks devirtualization, and inflates the stable-build cost that dominates
  cold-start latency. Apple moved off this model for the same reason. PreviewsMCP's current build
  pipeline already does not scale to 1000+ file modules; the thunk architecture inherits the same
  cold-start profile (the stable build is still a full module build) and adds pervasive call
  indirection as steady-state cost.
- **Agentic workflows.** Many fast renders per minute, not few slow ones. Per-render latency is
  the budget that determines whether agentic use is practical, and stable-build cost on a large
  module compounds across the loop.
- **Edit-anywhere semantics.** Thunk hot-swaps work cleanly inside the preview module; edits to
  transitively-reached dependencies force a stable rebuild. JIT-link patches arbitrary symbols at
  link time — that's the gap, and it's not bolt-on-able to the thunk model.

The research below is therefore load-bearing for the product, not exploratory. The question is
whether the architecture that delivers the product target is buildable on stable public layers —
not whether it's preferable to thunk.

## Research question

> Given the product target above — full Xcode Previews replacement, including large modules,
> agentic workflows, and edit-anywhere semantics — can PreviewsMCP build a JIT-style executor of
> its own on stable public layers (LLVM JITLink/ORC, `swiftc -emit-object`, Mach-O loader
> semantics, the public JIT entitlement) without depending on private Apple frameworks? And is
> the engineering investment tractable within a defensible budget?

The thunk architecture in `thunk-architecture.md` is the small-module holdover, not the
alternative. The question here is not "is JIT preferable to thunk" but "is the architecture that
reaches the product target buildable on public tooling, and at what cost." A positive verdict
means PreviewsMCP can deliver the product target. A negative verdict means it cannot on public
layers as of the spike date.

"Tractable within a defensible budget" is evaluated empirically against the spike's deliverables
(W1 / W2 / W3 below). The product properties driving the verdict — what the JIT executor must
achieve to be worth building — are:

- **Scales to large modules** without `-enable-implicit-dynamic`'s pervasive call indirection or
  the optimizer regressions it causes.
- **Build-artifact parity** with `xcodebuild` / Bazel Build & Run — no separate
  dynamic-replacement build pipeline contributing to cold-start cost or developer-tooling
  divergence.
- **Edit-anywhere hot-reload** — arbitrary symbols in transitively-reached source files, not only
  declarations within the preview module.
- **Long-term ABI stability** — built on Mach-O / LLVM JITLink semantics rather than the
  underscored `@_dynamicReplacement` attribute.

## Decision framing

Output is one of three judgments, written up as `prompts/jit-executor-findings.md`:

1. **Buildable; supersedes thunk for the product target.** Custom JIT executor is architecturally
   tractable on stable public layers within a defensible engineering budget, and clears the
   product properties listed above. Recommend pivoting `thunk-architecture.md`'s runtime-dylib
   delivery to a JIT-link delivery, keeping the file-watcher / stable-module / runtime split
   otherwise intact. Thunk remains shipped as the small-module path while the JIT executor builds
   out (multi-quarter).
2. **Buildable; sits alongside thunk.** Custom JIT is feasible but only pays off for a subset of
   the product target (e.g., Bazel targets where `-enable-implicit-dynamic` is awkward; modules
   above some size threshold where per-call indirection is measurable; edit-anywhere workloads).
   Ship thunk as the default and JIT as an opt-in fast path. The product target is reachable but
   across two architectures.
3. **Not buildable on stable public layers.** Patch-point selection, symbol-discovery infra, or
   concurrent-patching cost exceeds a defensible budget, **or** the public-layer building blocks
   (LLVM JITLink Swift coverage, relocation-info preservation) have unworkable gaps. Given the
   product target, this verdict is **not benign** — PreviewsMCP cannot reach the full Xcode
   Previews replacement scope on public tooling as of the spike date. Thunk remains the
   small-module shipping product; the large-module / agentic / edit-anywhere target is gated on
   upstream public-layer improvements (LLVM JITLink Swift coverage, relocation-info preservation
   tooling), willingness to revisit private-framework integration, or a different architecture
   not yet considered. Re-run the spike when any of those conditions change.

Each judgment must cite concrete evidence: traces of Apple's behavior, working/failing proof-of-
concept harnesses, measured deltas. "Looks hard" is not a conclusion.

## Why research-mode and not implementation

A full custom JIT executor for Swift previews is a multi-quarter engineering project. Before
committing to it, we need to bound four uncertainties:

1. **Patch-point selection.** Override semantics require patching the right indirections in
   the running process — Swift vtable slots, protocol witness table entries, generic metadata
   caches. Apple's XOJIT picks a specific set of these; figuring out which by reading Swift runtime
   source alone is hard. dtrace/lldb on a live XCPreviewAgent reveals it directly.
2. **Symbol-discovery infra.** Patching a call site requires knowing every site that references the
   old symbol. Relocation info is consumed at static-link time and not preserved in the loaded
   image. We need either a sidecar emitted during the stable build (custom linker pass /
   post-link tool) or a lazy intercept-on-call resolver. The research determines which is
   tractable.
3. **LLVM JITLink coverage for Swift.** JITLink is well-tested for C/C++/Rust object files;
   Swift's emission patterns (TLVs, async functions, protocol witness tables, runtime metadata
   registration) may surface gaps that haven't been exercised by JITLink's other clients
   (LLDB expression evaluator, ClangREPL, Julia). The proof-of-concept harness validates this.
4. **Concurrent-patching correctness.** Function-pointer swap while another thread is mid-call needs
   careful sequencing. Apple's stack handles this; we'd need to. The research extracts the pattern
   they use.

If all four resolve favorably, JIT-style execution becomes a real option. If any one is a hard
"no," the thunk architecture is the right path.

## Learning targets (reframed from `thunk-architecture.md`'s "three angles")

The Future Direction in `thunk-architecture.md:341-363` lists three angles as *delivery paths* —
ways to ride Apple's stack. We reframe them as *learning targets*: things to study via dtrace/lldb
in order to copy Apple's design choices, not their bytes.

### LT-1 — `PreviewsPipeline` step decomposition (was Angle C)

**Question:** How is Apple's 15-step pipeline (`docs/reverse-engineering.md:569-577`) decomposed?
Which steps produce object code, which produce link-time inputs, which manage agent lifecycle?
Where are the natural seams we'd put in our own pipeline?

**Method:** Dump every export of `Xcode.app/Contents/SharedFrameworks/PreviewsPipeline.framework`
via `dyld_info -exports … | xcrun swift-demangle`. Read public initializers on the 15 step types.
Structural dump via `class-dump-swift` (12 host-side `PreviewsPipeline` siblings, doc lines
107-122). Goal is a written architecture diagram of *Apple's* pipeline, captioned with the
analogous step we'd build ourselves.

**Priority:** Highest. Most directly informs *our* pipeline design.

### LT-2 — XCPreviewAgent lifecycle and patch-point set (was Angle A)

**Question:** What is the precise lifecycle of `XCPreviewAgent` from launch to first paint? Which
env vars gate which phases? Most importantly: at JIT-link time, *which symbols / vtable slots /
witness-table entries does the executor actually patch* to achieve override semantics?

**Method:** dtrace on `XCPreviewAgent`, `previewsd`, `PreviewShellMac` during a real preview
session (extends `docs/reverse-engineering.md:43-87` with full AMFI-off coverage). lldb attach to
running `XCPreviewAgent`; inspect state at `__previews_injection_*` entry points
(`docs/reverse-engineering.md:585-603`). Capture the *set* of patched indirections, not the
mechanism — Apple's mechanism is private; the set tells us which Swift-ABI surfaces our own
executor must reach.

**Priority:** Equally critical to LT-1 but more tractable to start (no framework-linking concerns).

### LT-3 — OOPJit page format (was Angle B)

**Question:** What does Apple's executable-page format look like at the byte level
(`docs/reverse-engineering.md:439-457`)?

**Method:** Hex-dump captured `cf.*` files; cross-reference with the source Swift to identify
function prologues and runtime-metadata references.

**Priority:** Lowest. Under the build-our-own framing, we never consume Apple's page format —
JITLink owns our object-code-to-runnable-pages step internally. LT-3 is interesting only as
disconfirmation ("Apple's pages don't reveal a clever trick we'd want to copy"). Capped at ~1 day.

## Research environment

A reproducible, disposable macOS VM that isolates the SIP/AMFI concession from any daily-driver
machine.

### Why a VM at all

- SIP off + AMFI off are required to dtrace/lldb Apple-signed binaries with restricted entitlements
  (XCPreviewAgent, previewsd, PreviewShellMac). Doing this on a host machine compromises that
  machine.
- Reproducibility: a contributor can land a one-line change that bumps the Xcode version under test
  and get a fresh, clean VM. Critical for regression checks across Xcode releases.
- The infra amortizes across all future RE work (e.g., the iOS host wire-protocol spike called out
  in `README.md`).

### Toolchain

- **Host requirement:** Apple Silicon. `Virtualization.framework` only supports macOS guests on
  Apple Silicon hosts. No Intel-host fallback.
- **VM provisioning:** A small in-repo Swift CLI under `research/vm/` that wraps
  `Virtualization.framework` directly. Responsibilities: download an IPSW, install macOS, take and
  restore snapshots, exec commands in the guest via SSH or virtio-serial. Approximately a few
  hundred lines of Swift, MIT-licensed as part of PreviewsMCP. Provisioning is shell scripts run
  inside the guest over SSH.

  **Why custom rather than off-the-shelf:**
  - **Tart** (`cirruslabs/tart`) is the obvious choice but ships under a Fair Source license that
    introduces commercial-use restrictions we'd rather not propagate into research infra.
  - **UTM** is GPL-3.0; mature and CLI-capable, but heavier than we need and copyleft is awkward
    for a research subdirectory.
  - **`macosvm`** (Apple's `Virtualization.framework` sample-based wrappers) is permissively
    licensed but minimally maintained; effectively the same effort as writing our own once you
    fork it.
  - Our automation surface is small (boot / snapshot / restore / exec) and the underlying API is
    public and stable. Writing it directly avoids any third-party licensing concern and keeps the
    dependency surface zero.

- **Drop Packer.** Packer's value-add is hypervisor abstraction; we target one hypervisor on one
  host architecture. Shell scripts driving our Swift CLI do everything Packer would, with less
  ceremony.

- **Boot-arg setup** (run via the in-guest provisioning script after first boot):
  - `csrutil disable` from recoveryOS (boot the VM with `--recovery`, run csrutil, reboot).
  - `nvram boot-args="amfi_get_out_of_my_way=1"` — separate from SIP. Without this, even with SIP
    off, `task_for_pid` and `ptrace` against entitlement-restricted binaries return EPERM.

- **Snapshot strategy:** Take a base snapshot after first boot + Xcode install + SIP/AMFI off.
  Every research session resets to that snapshot, so no accumulated state contaminates traces.

### Instrumentation

Python is glue, not the primary tool — the real work is in dtrace scripts and lldb commands.

- **dtrace:** `pid$target`, `syscall`, and `objc$target` providers against `Xcode`, `XCPreviewAgent`,
  `previewsd`, `PreviewShellMac`. Extends `docs/reverse-engineering.md:43-87` patterns with full
  coverage now that AMFI is out of the way. Python wraps `dtrace -s script.d -p $PID` and parses
  output streams.
- **lldb:** `import lldb` (first-class Python API). Attach to a running `XCPreviewAgent`, inspect
  JIT-executor state at `__previews_injection_*` entry points, dump vtables / witness tables
  before and after a JIT-link to identify patched indirections.
- **`dyld_info -exports` + `xcrun swift-demangle`:** enumerate `PreviewsPipeline.framework`
  initializers and step types. First concrete starting point per `thunk-architecture.md:381-382`.
- **`class-dump-swift` / `class-dump`:** structural dumps of the `PreviewsPipeline` siblings.
- **LLVM JITLink (via `llvm-jitlink` first, then a C++/Swift harness):** the load-bearing
  proof-of-concept tooling. Validates that the public layer can actually do what we need.

## Workstreams

Three workstreams. W1 infra unblocks both research streams; W2 and W3 inform each other but don't
strictly block.

### W1 — Research VM infra

**Outputs:** `research/vm/` containing the Swift `Virtualization.framework` wrapper CLI, the
post-install provisioning scripts (Xcode install, SIP/AMFI off, snapshot), and a `README.md`
documenting "how to spin up a SIP+AMFI-off macOS VM with Xcode N installed." Plus a Python harness
under `research/scripts/` wrapping the dtrace/lldb workflows.

**Done when:** a contributor can clone the repo, run a single command, and end up at an lldb prompt
attached to a running `XCPreviewAgent` inside a clean VM. No manual recoveryOS dance per session.

### W2 — `PreviewsPipeline` study + JITLink proof-of-concept (covers LT-1 and the LLVM-coverage uncertainty)

**Outputs:** Two artifacts.

1. An architecture diagram of Apple's 15-step pipeline, captioned with the analogous step we'd
   build ourselves and the public layer that would back it (e.g., "Apple's `WorkCollectionStep` →
   our PreviewSession discovery, no analogue needed at runtime"; "Apple's JIT-link step →
   `llvm::orc::ObjectLinkingLayer` + custom `JITLinkPlugin` for override semantics").
2. A minimal harness that takes a Swift `.o` produced by `swiftc -emit-object`, JIT-links it via
   LLVM ORC's `ObjectLinkingLayer`, resolves symbols against a host process, and demonstrates a
   trivial function override — i.e., calling `foo()` in the host returns the original definition
   before the JIT-link and the new definition after. **This is the load-bearing experiment.** If
   JITLink can't link Swift `.o` files (because of TLV / async / witness-table emission patterns it
   doesn't handle), the entire build-our-own path is gated on either patching JITLink upstream or
   replacing the JIT layer — both are large commitments.

**Done when:** the harness demonstrably overrides a Swift function call in a host process, and the
architecture doc identifies a public-layer analogue for every Apple pipeline step.

### W3 — XCPreviewAgent lifecycle + patch-point set (covers LT-2)

**Outputs:** Two artifacts.

1. A labeled timeline of `XCPreviewAgent` from launch to first paint (env vars consumed at each
   stage, entry-point fallback chain, message order — extends
   `docs/reverse-engineering.md:581-603`).
2. **The patch-point set.** Before/after diffs of the agent's loaded image at JIT-link time:
   which vtable slots changed, which witness-table entries changed, which symbol stubs were
   rewritten. This is the single most valuable artifact of the entire spike — it tells us *exactly*
   which Swift-ABI surfaces our own executor must reach to achieve equivalent override semantics.

**Done when:** we have a documented patch-point set and a lifecycle timeline; W2's harness can be
extended (post-spike) to target those same patch points.

LT-3 (OOPJit format) folds into W3 as a 1-day side-task — captured if useful, dropped if not.

## Deliverables

1. `research/vm/` — Swift `Virtualization.framework` wrapper CLI + provisioning scripts (W1).
2. `research/scripts/` — Python wrappers for dtrace/lldb workflows (W1).
3. `prompts/jit-executor-findings.md` — the decision document. Structure: research question, what
   was tried, what worked, what didn't, the verdict (supersedes / alongside / not worth it), and
   the evidence trail. **This is the load-bearing artifact.**
4. If verdict is "supersedes" or "alongside": `prompts/jit-executor-design.md` — a design document
   for our own JIT executor, including the patch-point set, the symbol-discovery strategy, the
   JITLink plugin architecture, and the concurrent-patch sequencing approach. This is what unlocks
   actual implementation work as a follow-on project.
5. Updated `thunk-architecture.md` — verdict note regardless of outcome.

## Exit criteria

The spike exits — and `jit-executor-findings.md` is written — when **all three** are true:

- W3 produces a patch-point set (we know which Swift-ABI surfaces to reach).
- W2's harness either successfully overrides a Swift function call via JITLink **or** documents the
  specific JITLink coverage gap that blocks it.
- The architecture doc identifies a public-layer plan for every Apple pipeline step **or**
  documents the specific step that has no public analogue.

If the timebox elapses without all three, the verdict **is** "not worth the budget allocated";
revisit later if priorities shift.

The spike does **not** exit on LT-3 (OOPJit format study) alone — under the build-our-own framing,
the format is incidental.

## Timebox

**Soft budget: 3 working weeks**, broken roughly as:

- **W1 infra: ~5 days.** Custom `Virtualization.framework` CLI takes longer than Tart would have,
  but it's a one-time cost amortized across all future research. Most of the time is the AMFI/SIP
  recoveryOS automation (driving recovery boot from outside the guest, scripting the in-recovery
  csrutil call) and getting an Xcode install reproducible.
- **W2 study + POC: ~9 days.** Architecture doc is ~2 days; the JITLink POC is ~7 days. Most of
  the POC cost is the first encounter with a Swift-emission pattern JITLink doesn't gracefully
  handle.
- **W3 lifecycle + patch points: ~5 days.** The patch-point work is the deepest of any single
  task — diffing vtables before/after a JIT-link, identifying which slots changed, mapping back to
  source-level Swift constructs.

Three weeks is a soft cap. If at the end of week three there's no verdict in sight, the verdict
**is** "not worth the budget allocated." Don't slip the cap silently.

## Non-goals

- **No riding on Apple's stack.** We don't link `PreviewsPipeline.framework`, we don't drive
  `XCPreviewAgent` over `HostAgentSystem`, we don't consume OOPJit page format. These are
  *reference designs*, not runtime dependencies. (If the verdict is "supersedes" we will *resemble*
  Apple's architecture; we will not *call into* it.)
- **No OOPJit byte-level RE beyond a 1-day side-task.** The format is incidental under the
  build-our-own framing.
- **No production code.** Nothing in `research/` ships in `Sources/`. The JITLink POC is throwaway
  validation, not the first commit of the eventual executor. Only the findings doc, optional design
  doc, and `thunk-architecture.md` edits outlive the spike.
- **No iOS host-app wire-protocol work.** Adjacent territory, separate doc
  (`prompts/ios-host-wire-protocol.md`). Reuses the VM infra from W1.
- **No commitment to multi-Xcode-version maintenance.** Spike runs against one Xcode version
  (current GA at start of spike). Findings doc notes "verified against Xcode X.Y."
- **No third-party VM tooling with restrictive licensing.** Tart in particular is excluded; UTM and
  `macosvm` are noted as alternatives but we default to our own thin wrapper.

## Dependencies

- **Reads from:** `docs/reverse-engineering.md` (full doc — empirical basis).
  `thunk-architecture.md:326-392` (Future Direction — the foundation this scope reframes).
- **Writes back to:** `thunk-architecture.md` (verdict note, regardless of outcome).
- **Independent of:** `path-resolution.md` (implemented), `filewatcher.md` (no overlap),
  `modularization.md` (different surface), the `@_dynamicReplacement` viability spike (which
  validates the thunk fallback — orthogonal to whether a custom JIT executor is preferable).

## Relationship to the viability spike

The `@_dynamicReplacement` viability spike (`README.md` open follow-ups; would produce
`prompts/dynamic-replacement-spike.md`) and this research answer different questions:

- The viability spike answers: "does thunk work as a small-module shipping product, and as the
  holdover while JIT research runs?"
- This research answers: "can PreviewsMCP reach the full product target on stable public layers?"

Both questions matter; they're not substitutes. Under the product framing in this doc, a
"not buildable" verdict here is already existential for the large-module / agentic /
edit-anywhere target regardless of the spike's outcome. The spike's outcome determines whether
the small-module holdover is even available while that's being figured out.

Recommended order: viability spike first (cheap, decisive — locks in or eliminates the holdover),
then this scope. W1's VM infra is useful regardless of the spike's outcome, so kicking off W1 in
parallel with the viability spike is reasonable.

If the viability spike fails *and* this research returns "not buildable," PreviewsMCP has
neither a small-module shipping product nor a path to the large-module target on public tooling.
Remaining options reduce to upstream LLVM JITLink work, revisiting the private-framework
integration this doc currently excludes, or accepting the product scope cannot be delivered.

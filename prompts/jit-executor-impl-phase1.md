# JIT executor implementation — Phase 1 seed prompt

**Status:** The W3 spike closed with verdict #1 ("buildable; supersedes thunk for the product target"). Empirical capture across 11 edit kinds confirms Apple uses respawn-only — no in-place patching — for SwiftUI hot-reload. The design doc + POC code answer every load-bearing risk the spike was supposed to retire. **Phase 1 implementation should begin.**

This file is a self-contained seed prompt for a fresh-context agent picking up Phase 1. Copy-paste into the first turn of a new session.

---

## Seed prompt (copy below this line)

I'm starting Phase 1 of the JIT-executor implementation. The research spike has closed; the design doc and POC code are ready inputs. Goal of Phase 1 is the host-side in-process LLVM ORC + JITLink harness inside the PreviewsMCP daemon (`previewsmcpd`).

**Required reading, in order. Don't skip — each one provides load-bearing context the next ones build on.**

### 1. The verdict and architecture (15 min)

- [`prompts/jit-executor-findings.md`](jit-executor-findings.md) (on `main`) — the spike's committed verdict #1. Establishes "we build this on public LLVM ORC + JITLink, not on Apple's runtime."
- [`prompts/jit-executor-design.md`](jit-executor-design.md) §§1–8 — the design specification you're implementing. **§8.1 is your Phase 1 spec.** Read all of §§1–8 once; you'll come back to §3 (symbol discovery), §4 (plugins), and §7 (build pipeline) during implementation. §9–10 are open questions and explicit non-scope.
- [`prompts/jit-executor-research.md`](jit-executor-research.md) "Non-goals" — what NOT to do. Read this before reaching for any Apple-private symbol; the answer is always "we use the public-API equivalent."

### 2. What we empirically know about Apple's runtime (20 min)

These docs back the design with evidence; if your implementation matches the model here, you'll mirror Apple's architecture without copying any of Apple's bytes.

- [`research/scripts/analysis/q6-jit-runtime-findings.md`](../research/scripts/analysis/q6-jit-runtime-findings.md) — Apple's `XOJITExecutor.framework` is statically-linked LLVM ORC + JITLink behind a Swift/XPC façade. The wire vocabulary is LLVM's `SimpleRemoteEPC`. This is *the* finding that makes Phase 1 + 2 feasible on public APIs.
- [`research/scripts/analysis/w3-empirical-capture.md`](../research/scripts/analysis/w3-empirical-capture.md) — what the agent actually does per edit. Three `run_program_*` calls per hot-reload, zero `write_mem` calls, full respawn-per-edit. Section "Session-7 update" is the most authoritative.
- [`research/scripts/analysis/w3-patch-point-set.md`](../research/scripts/analysis/w3-patch-point-set.md) §§1–5 — the Swift-ABI surfaces JITLink can in principle touch (PWT, vtable, GOT, stubs, async entry/ret, TLV, swift_once, ObjC selref, ObjC class). §3's table is the universe of relocations the plugin set must handle. §6 establishes that Apple exercises *none* of these for in-place patching — but our plugins still need to emit them correctly when the agent JIT-links a fresh image.

### 3. The W2 POC — your starting code base (1–2 hours)

The POC is a working in-process LLVM ORC + JITLink harness in C++ that already covers six Swift emission patterns. Phase 1 is mostly wrapping this in Swift + wiring to PreviewsMCP's daemon plumbing.

- [`research/jit-poc/SCOPE.md`](../research/jit-poc/SCOPE.md) — what the POC tested.
- [`research/jit-poc/src/host_objc.cpp`](../research/jit-poc/src/host_objc.cpp) — the most complete harness. Single-file demonstration of LLJIT + ObjectLinkingLayer + the ObjCSelrefPlugin. Phase 1's harness derives from this.
- [`research/jit-poc/src/ObjCSelrefPlugin.{cpp,hpp}`](../research/jit-poc/src/ObjCSelrefPlugin.cpp) — the JITLink plugin that walks `__DATA,__objc_selrefs` at link-finalize and calls `sel_registerName` for each cstring. **Pattern for any MachOPlatform-augmenting plugin** — you'll write a structurally-identical `ObjCClassPlugin` for `__DATA,__objc_classlist` early in Phase 1.
- [`research/jit-poc/build.sh`](../research/jit-poc/build.sh) — the working toolchain incantation. Brewed LLVM 22 + swiftc from Xcode 26.2 SDK + ORC runtime archive. Get this building locally before you touch anything else.
- [`research/jit-poc/data/`](../research/jit-poc/data/) — per-phase run logs. Skim a few; gives you the "what success looks like" smell.

### 4. The daemon side you're integrating into (30 min)

- [`Sources/PreviewsMCPCore/Compiler.swift`](../Sources/PreviewsMCPCore/Compiler.swift) — existing `swiftc -emit-object` driver. Phase 1 reuses this for `.o` production; you don't need to invent it.
- [`Sources/PreviewsMCPCore/FileWatcher.swift`](../Sources/PreviewsMCPCore/FileWatcher.swift) — existing file-watch mechanism. Phase 1 plugs into this for "source changed → re-JIT" trigger.
- [`Sources/PreviewsMCPCore/SessionResolver.swift`](../Sources/PreviewsMCPCore/SessionResolver.swift) — existing session-per-preview architecture. Phase 1 adds one new session kind (`jit-linked` vs the existing `runtime-dylib`).
- [`prompts/thunk-architecture.md`](thunk-architecture.md) — what we're replacing. Includes the verdict-note pointing at this work.

### 5. Toolchain gotchas to know before you start (10 min)

These will bite you on day 1 if you don't know them. Pulled from the POC's "learned the hard way" notes.

- Use `$(brew --prefix llvm)/bin/clang++` for the C++ harness. **Do NOT use `xcrun clang++`** — that's Xcode's clang, not brew LLVM's, and it can't link against brew LLVM's libraries.
- swiftc on macOS 26.x rejects `-target arm64-apple-macos26.0`. Use `-sdk $(xcrun --sdk macosx --show-sdk-path)` instead.
- arm64 only (Apple Silicon host). The fat `liborc_rt_osx.a` has an arm64 slice; thin it before linking if you hit lipo errors.
- JITLink Plugin base is `LinkGraphLinkingLayer::Plugin`, not `ObjectLinkingLayer::Plugin` (the latter inherits the former). Header: `<llvm/ExecutionEngine/Orc/LinkGraphLinkingLayer.h>`.
- Pure-virtual methods that MUST be implemented even as no-ops: `notifyFailed`, `notifyRemovingResources`, `notifyTransferringResources`.
- `PostPrunePasses` is the right pass phase for edge retargeting (NOT `PreFixupPasses`).
- LinkGraph section names use canonical Mach-O `__SEG,__sect` form (`__DATA,__objc_selrefs`), not bare names.

### Phase 1 goal (from design doc §8.1)

**A new `Sources/PreviewsJITLink` target inside PreviewsMCP that, in-process inside `previewsmcpd`, can:**

1. Accept a Swift source file + a target SwiftUI `View` symbol from `SessionResolver`.
2. Invoke the existing `Compiler.swift` to produce a `.o`.
3. Feed that `.o` into an `LLJIT` instance + `ObjectLinkingLayer` with three plugins:
   - `ObjCSelrefPlugin` (port from POC verbatim).
   - `ObjCClassPlugin` (new, structurally identical to selref plugin).
   - `SwiftEntrySectionPlugin` (new, scans `__TEXT,__swift5_entry` + family, calls Swift runtime registration APIs at link-finalize time).
4. Resolve the View symbol's address against the daemon's own loaded image table (via `dlsym`) + the JIT'd image.
5. Invoke the View's body via standard Swift calls. **Phase 1 runs JIT'd code in the daemon's own process; no agent yet.**
6. On source-file change (`FileWatcher` signal): recompile via Compiler, add the new `.o` to the same `LLJIT`, re-resolve the symbol. The new address replaces the old one in any caller's lookup. Validate by calling the new symbol and observing the change.

**Acceptance:** A new `PreviewsJITLinkTests` test-suite mirroring the POC's six Phase 2 scenarios:
- Witness override (POC `host_witness.cpp` validates the mechanism).
- TLV (`host_tlv.cpp`).
- `swift_once` global init (`host_tlv.cpp`, same suite).
- ObjC selref via the plugin (`host_objc.cpp`).
- ObjC class registration via the NEW plugin (gap to close).
- Async multi-await (`host_async.cpp`).

Each test ships as a Swift source + an assertion that the JIT-linked function returns the expected value. The tests run in-process inside the test runner.

**Sizing:** ~6 weeks per design doc. The bulk of the cost is integrating LLVM 22 into PreviewsMCP's build (vendoring vs SwiftPM dependency vs CMake bridge); the JIT-link logic itself is mostly already in the POC.

### Out of scope for Phase 1

- **Out-of-process agent.** That's Phase 2.
- **Wire protocol.** Phase 2 picks `SimpleRemoteEPC` defaults.
- **Bazel integration.** Phase 3.
- **iOS device support.** Phase 4+.
- **In-place patching / `write_mem`.** Apple doesn't use it (empirically); we don't need it for parity. Stays as a deferred Phase-4 optimization for state-preservation use cases.
- **Reverse-engineering Apple's XPC payload bytes.** We're not riding on Apple's stack; our wire protocol is LLVM's, defined by the LLVM source we link against.
- **`xcodebuild -emit-object` instead of `swiftc -emit-object`.** Compiler.swift's existing swiftc path works.

### Starting move (do this first)

1. **Get the POC building locally.** `cd research/jit-poc && ./build.sh && ./build/host_objc build/objc_v1.o` (from a checkout of `previews-research`). If you can't reproduce the POC's success, fix that before integrating anything. The toolchain gotchas in §5 above are the most common failures.
2. **Read the design doc §3 and §4 fully.** §3's symbol-discovery strategy (sidecar from custom linker pass + lazy fallback) is the load-bearing complexity of Phase 1; §4 is the plugin architecture. If you start coding before understanding both, you'll architect the wrong thing.
3. **Architect the LLVM integration.** The single biggest decision Phase 1 makes: how does PreviewsMCP's Swift Package Manager build link against LLVM 22? Options in priority order: SwiftPM binary-target with prebuilt LLVM xcframework (cleanest, most work to set up); vendor brew LLVM via a CMake-driven build step (matches POC, most familiar); pull from a Swift-wrapped LLVM package (Apple's `swift-llvm-bindings` doesn't expose ORC). Pick this BEFORE writing any Swift code; it determines the whole module's shape.
4. **Stub the Swift API surface.** Before integrating LLVM, write the Swift types Phase 1 will expose: `JITLinkSession`, `JITLinkResult`, `JITLinkError`, `Symbol`. Mock the implementation. Add to `SessionResolver` as a new session kind. Lands a stable surface for the rest of `previewsmcpd` to consume while you wire LLVM underneath.
5. **Port `ObjCSelrefPlugin` to Phase 1's harness.** Smallest possible win — proves the LLVM integration works end-to-end. Once this plugin runs inside the daemon and the unit test passes, you've cleared the highest-risk implementation hurdle.

### Working environment

- Use the `jit-implementation` (or similar) branch off `main`. Don't work on `previews-research` — that's the research branch with the VM bundle, the POC, and the spike artifacts.
- The POC is at `research/jit-poc/` on the `previews-research` branch. It's read-only reference material — don't edit it; copy patterns into your new code.
- Run tests via `swift test` from the repo root. Integration tests against example projects live under `examples/`.
- For the test fixtures (the six POC scenarios), translate the Swift sources from `research/jit-poc/swift/*.swift` (on `previews-research`) into proper SwiftPM test targets.

### What "Phase 1 done" looks like

- New `Sources/PreviewsJITLink` target builds and links against LLVM 22 inside the daemon.
- Six unit tests pass, covering each POC Phase-2 scenario.
- An integration test under `examples/` opens a SwiftUI preview, edits the source, and verifies the JIT-linked output reflects the edit.
- `prompts/jit-executor-design.md` §8.1 has a closure note pointing at the Phase 1 PR.
- The Phase-2 (agent + SimpleRemoteEPC) seed prompt gets written as a sibling to this file.

**Stop here. Start implementing.** Don't go back into the research artifacts looking for more answers — the design doc has them, and if it doesn't, that's a Phase 1 discovery, not a research re-opening.

---

End of seed prompt.

---

## Provenance

- Spike verdict: [`prompts/jit-executor-findings.md`](jit-executor-findings.md), committed on `main` at `5fd21e2`.
- Design doc: [`prompts/jit-executor-design.md`](jit-executor-design.md), on `previews-research`.
- Empirical capture: `research/scripts/analysis/w3-empirical-capture.md` + `w3-patch-point-set.md` + `q6-jit-runtime-findings.md`, on `previews-research`.
- W2 POC: `research/jit-poc/`, on `previews-research`, 6 green Phase-2 scenarios.
- Verified-against: macOS 26.3.1, Xcode 26.2 (Build 17C49), Swift 6.2.3, LLVM 22.

If this file is more than a quarter ahead of the design doc's pace, the design doc is the authority. Update this prompt when Phase 1 lands; it should always reflect the actual state of what's been built and what comes next.

# PreviewsMCP design docs

In-progress design documents for the PreviewsMCP rearchitecture. Each is scoped to one concern; together
they form the planned next-generation hot-reload pipeline and module layout. Once a doc's work lands,
its content gets folded into `docs/architecture.md` or the relevant module's docs and the prompt is
archived — not deleted, since the design rationale is useful as historical record.

## Documents

| Document | Concern | Status |
|---|---|---|
| [modularization.md](modularization.md) | Module layout, target/session split, `PreviewsBuild` extraction | Draft |
| [filewatcher.md](filewatcher.md) | Replace polling with FSEvents | Implemented (PR #179, pending archive) |
| [thunk-architecture.md](thunk-architecture.md) | Three-dylib hot-reload via `@_dynamicReplacement` — small-module holdover while JIT research runs | Draft (one open subsection — iOS host wire protocol) |
| [jit-executor-research.md](jit-executor-research.md) | JIT executor on public layers — path to the full product target (any-scale Xcode Previews replacement, agentic workflows) | Draft (scope) |
| [path-resolution.md](path-resolution.md) | Daemon-side path canonicalization (tilde, symlinks, normalization) | Implemented (pending PR + archive) |
| [dynamic-replacement-spike.md](dynamic-replacement-spike.md) | Per-shape viability of `@_dynamicReplacement` — preserved on branch [`spike/dynamic-replacement`](https://github.com/obj-p/PreviewsMCP/tree/spike/dynamic-replacement) and closed [PR #178](https://github.com/obj-p/PreviewsMCP/pull/178); not merged forward — see doc for the strategic reason | Complete, preserved as research (8/8 rows verified) |

## Sequencing

The docs fall into two tracks toward the product target (full Xcode Previews replacement at any
scale, including agentic workflows):

- **Small-module holdover track** — `filewatcher` + `modularization` + `thunk-architecture`.
  Ships while the product-target track is built out. Does not scale to large modules; see
  `jit-executor-research.md` → "Product target."
- **Product-target track** — `jit-executor-research` and its multi-quarter follow-on
  implementation. The architecture that actually delivers any-scale Previews replacement.

The `@_dynamicReplacement` viability spike is a hard prerequisite for the holdover track and also
feeds the product-target track's findings (determines whether thunk is a viable holdover during
JIT buildout).

```
path-resolution         ✅ implemented
viability spike         ✅ complete, preserved on `spike/dynamic-replacement`
                            (NOT merged forward — see dynamic-replacement-spike.md)
filewatcher             ✅ implemented (PR #179)

modularization          foundational — reusable for either track

jit-executor-research ──▶ JIT executor implementation
                          (path to full product target;
                           multi-quarter follow-on if "buildable" verdict)

thunk-architecture      gated on JIT verdict + 4 unverified risks
                            (codesign cost, implicit-dynamic perf,
                             VFS diagnostics, Bazel injection)
```

Order of operations:

1. **path-resolution.md** — ✅ **implemented** on `rewrite`. `Path.normalize(_:)` /
   `Path.normalizeURL(_:)` live in `PreviewsCore`. Wired into every CLI parse site (`run`,
   `snapshot`, `variants`, `list`), `SessionResolver`'s `--file` lookup, the daemon MCP handlers
   (`preview_list`, `preview_start`, including `projectPath` and the now-honored `config` param),
   `BuildHelpers.loadProjectConfig`, and the `PREVIEWSMCP_SOCKET_DIR` env override. `PathTests`
   pins the contract (tilde, `~user`, `./..`, symlinks, non-existent, empty, canonical absolute,
   `normalizeURL`/`normalize` agreement). Code-reviewed and applied; pending PR + archive of the
   doc into `docs/architecture.md`.

   **Lesson for future docs:** the doc proposed "one boundary: the daemon," but the daemon runs
   in a separate process with a different CWD than the CLI — relative paths sent verbatim resolve
   against the daemon's launch directory, not the user's. Implementation normalizes on **both**
   sides (CLI absolutizes pre-transit; daemon re-normalizes on receipt to also cover non-CLI MCP
   clients). Worth folding into the doc when archiving.
2. **filewatcher.md** — ✅ **implemented** on `main` via [PR #179](https://github.com/obj-p/PreviewsMCP/pull/179).
   `Sources/PreviewsCore/FileWatcher.swift` is now FSEvents-backed: one watch per unique canonical
   parent directory, ~50ms latency (~10× faster than the prior 500ms polling cadence), filters
   incoming event paths against a `realpath()`-canonicalized `Set<String>`. The public API is
   unchanged except the now-meaningless `interval:` parameter was removed; no production call sites
   passed it. New regression tests in `Tests/PreviewsCoreTests/IntegrationTests.swift` cover the
   cases polling didn't: atomic-rename save (the headline FSEvents fix — verified by inode-change
   assertion), back-to-back saves within the latency window (≥1 callback, coalescing allowed), and
   delete-and-recreate save pattern (per-cycle assertion). End-to-end validation against
   `examples/spm` confirmed hot-reload works for in-place edits, atomic-rename saves, and
   cross-file edits. Pending archive of the doc into `docs/architecture.md`.

   **Lesson for future docs:** the design doc didn't get into Unmanaged semantics, but the C-API
   interop forced a non-obvious choice. `Unmanaged.passUnretained(self)` for the FSEvents
   `info` pointer is the natural first attempt and has a real UAF race: a callback enqueued on the
   watcher's dispatch queue can fire against a `self` whose `deinit` has started. `passRetained(self)`
   fixes the race but leaks because the only thing that drops the +1 is `FSEventStreamRelease`,
   which is called from `stop()`, which is called from `deinit`, which can never run. The
   implementation uses a third option: a `CallbackBox` holding the callback state (canonical paths +
   closure), handed to FSEvents with retained semantics + a matching `release` callback in the
   context. The trampoline dereferences `box`, not `self`, so callback lifetime is decoupled from
   watcher lifetime — race-free and leak-free without requiring callers to call `stop()`
   pre-deinit. Worth folding into any future doc that hands Swift state to a C API with
   asynchronous callback delivery.
3. **`@_dynamicReplacement` viability spike** — ✅ **complete, preserved as research** on
   branch [`spike/dynamic-replacement`](https://github.com/obj-p/PreviewsMCP/tree/spike/dynamic-replacement)
   ([closed PR #178](https://github.com/obj-p/PreviewsMCP/pull/178)). All 8 rows verified on
   Swift 6.2.3 / Xcode 26.2. The spike's empirical findings are in
   `prompts/dynamic-replacement-spike.md`. **Not merged forward** — the foundation-first work
   below is preferred over committing to the thunk track before the JIT verdict is in and the
   four unverified risks (codesign cost, implicit-dynamic perf, VFS diagnostics, Bazel
   injection) are closed. Regression tests live at
   `Tests/PreviewsCoreTests/DynamicReplacementSpike/` on the preservation branch.
4. **modularization.md** — establishes `PreviewsBuild` and the `BuildTarget` / `PreviewSession`
   split. Blocks `thunk-architecture.md` because the thunk doc references both `PreviewsBuild` and
   the `BuildTarget` abstraction throughout. Much of the surface (target-vs-session split,
   build-subsystem extraction) is likely useful to the JIT track too, but the specific shape was
   designed against thunk; expect some revisiting when JIT research lands.
5. **thunk-architecture.md** — small-module hot-reload via `@_dynamicReplacement`. **Gated** on
   (a) the JIT research verdict (step 6 below) and (b) a measurement spike that closes the four
   unverified risks the viability spike couldn't reach from a single macOS process: iOS
   codesigning iteration cost, `-enable-implicit-dynamic` perf on real SwiftUI hierarchies,
   `-vfsoverlay` diagnostic correctness, Bazel `-enable-implicit-dynamic` injection. Only
   committed to if JIT comes back not-buildable / buildable-alongside AND the four risks turn
   out tractable. The remaining open subsection — iOS host-app wire protocol (three-dylib
   delivery design) — also waits on that gate.
6. **jit-executor-research.md** — 3-week timeboxed research spike on whether PreviewsMCP can build
   its own JIT executor on stable public layers (LLVM JITLink/ORC, public JIT entitlement) without
   Apple private-framework dependencies. Verdict is buildable-supersedes / buildable-alongside /
   not-buildable. W1 (VM infra) may overlap with the viability spike. Implementation of the JIT
   executor is a multi-quarter follow-on, gated on a "buildable" verdict.

## Open follow-ups

Worth doing alongside or after the primary tracks above:

- **`docs/architecture.md` + `AGENTS.md` sync.** Both currently describe the unified-compile model
  and the pre-rearchitecture module layout. After modularization + thunk-architecture lands, both
  need a refresh pass — particularly the "Build context" section in `architecture.md` and the
  module-layout description in `AGENTS.md`. Also: `AGENTS.md:60, 132` already need updating for the
  HostAppSource move (see modularization.md → "Host-app source").
- **iOS host-app wire protocol** (already called out in thunk-architecture.md). Three-dylib
  delivery, code-signing per artifact, RTLD flag choices, stable-dylib swap signaling. Likely wants
  its own short doc — `prompts/ios-host-wire-protocol.md`.
- **Bazel + `-enable-implicit-dynamic` feasibility** (called out in thunk-architecture.md's Risks
  section). `rules_swift` defers more to Bazel than our direct-swiftc paths. May require user-side
  `copts` changes or a Bazel aspect. Worth a feasibility check before claiming Bazel parity for the
  thunk architecture.
- **`BuildTarget` GC policy.** Modularization proposes refcount-based eviction with a 5-minute keep-
  warm. Worth validating against actual usage patterns once the daemon supports concurrent multi-
  session workloads.
- **`@_private(sourceFile:)` fallback.** Thunk-architecture risks a future Swift toolchain breaking
  the underscored attribute. Fallback is `@testable import` + `-enable-testing` on the stable build,
  but the visibility semantics differ slightly (public-but-not-API vs all-internal). Worth a
  decision-tree doc if/when that day comes.

## Cross-doc dependencies

For implementation planning:

- `modularization.md` → `thunk-architecture.md`: target/session split, `PreviewsBuild` extraction.
- `filewatcher.md` → `thunk-architecture.md`: the two-watcher split (preview-file vs module-files)
  assumes the new FSEvents implementation handles multiple watched roots cleanly.
- `path-resolution.md` → `modularization.md`: the `Path.normalize` helper home is `PreviewsCore`,
  which the modularization doc inherits without changes.
- `thunk-architecture.md` → `docs/reverse-engineering.md`: cited throughout for the empirical
  basis of the architecture (Xcode's three-tier update model, JIT executor mechanics, build
  artifacts, captured wire formats).

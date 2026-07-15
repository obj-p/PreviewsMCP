# Build System Resolver: owner(file) and compileContext(target)

Status: DRAFT for review — 2026-07-15

PreviewsMCP currently answers "which project owns this file" by trying build
systems in a fixed order, each walking up to its nearest marker, without ever
confirming that the chosen project actually contains the file. It then answers
"how do I compile this target" by re-deriving a thin flag set (`-I`/`-F`/`-L`)
from directory scans and partial tool output, dropping every other
compile-affecting setting. These two guesses are the root cause of roughly 20
reproduced rows in `examples/regress/VERIFICATION.md`.

This design replaces both guesses with one contract per build system: an
`owner(file)` query that only claims a file when the build system's own model
confirms membership, and a `compileContext(target)` that reproduces the native
build's actual compile command instead of re-deriving an approximation of it.
The recommended source of truth is **capture from the real build** (llbuild
manifest for SwiftPM, `aquery` for Bazel, build-log/settings capture for
Xcode), because the native build already runs on every session start and its
command line is closed-form ground truth, while setting-by-setting
interrogation is an open-ended catalog that fails on every setting not yet
mapped.

## Matrix rows this retires

| Family | Rows | Shared root cause |
|---|---|---|
| Ownership guessed | D01, D03, D04, D07, D08, X02 (detection half) | Fixed order SPM→Bazel→Xcode (`PreviewsCore/BuildSystem.swift:78-90`); each `detect` returns the nearest own-marker with no membership check (`SPMBuildSystem.swift:151-166`), so the repo-root `Package.swift` claims files that live in nested Xcode/Bazel projects |
| No ownership diagnostics | D06 | Detection returns a bare system or nil; nothing reports the candidate markers found and why each declined |
| Compile context re-derived | S01–S05, X01, X02 (compile half), B01, B02, B03 | `BuildContext` carries only `moduleName` + search-path flags + a scanned source list (`BuildContext.swift:4-50`); defines, language mode, upcoming features, bridging headers, macro plugin flags, exclusions, and generated inputs are dropped |
| Identifier fidelity | D09 | Generated module names are built from raw file names; Unicode/space paths produce invalid identifiers |

Guards that must keep passing: D02, D05 (with the tie-break documented), S06.

Not addressed here (separate families): thunking (C01/C02/V02), state
invalidation (C03–C05, W02, W04), phase/error protocol (F01, R01, T-, L-, P01),
semantic interaction (I01–I03). One enabler worth noting: a captured input
list gives the watcher the true source set, including `.package(path:)`
dependency sources, which is the missing prerequisite for W04.

## Today's shape (evidence)

- Dispatch: `BuildSystemDetector.detect` tries SPM, then Bazel, then Xcode;
  first non-nil wins (`PreviewsCore/BuildSystem.swift:78-90`). An override
  (`--build-system`) short-circuits via `forced(...)` (`:97-131`).
- Each `detect` walks up from the source file to `/` and returns the nearest
  own-marker: `Package.swift` (`SPMBuildSystem.swift:151-166`),
  `MODULE.bazel`/`WORKSPACE*` (`BazelBuildSystem.swift:21-42`),
  `*.xcworkspace`/`*.xcodeproj` (`XcodeBuildSystem.swift:33-53`). None asks
  whether the found project contains the file.
- `build(platform:)` produces `BuildContext { moduleName, compilerFlags,
  projectRoot, targetName, frameworkPaths, sourceFiles? }`
  (`PreviewsCore/BuildContext.swift:4`). `-target`/`-sdk` are injected later by
  `Compiler` (`Compiler.swift:45-46`); nothing carries defines, `-swift-version`,
  `-enable-upcoming-feature`, `-import-objc-header`, or
  `-load-plugin-executable`. The Xcode flag extractor explicitly keeps only
  `-I`/`-F`/`-Xcc` (`XcodeBuildSystem.swift:499-543`).
- Tier 2 source lists: SPM enumerates every `.swift` under the target
  directory (`SPMBuildSystem.swift:552-584`) — exclusions ignored (S04),
  plugin-generated sources missed (S03). Xcode reads OutputFileMap keys
  (`XcodeBuildSystem.swift:270-293`) — closest to truth today. Bazel queries
  `labels(srcs, target)` (`BazelBuildSystem.swift:523-548`) but passes
  generated labels as workspace-relative paths (B01).
- Capture precedent already in-tree: `-package-name` is read out of SPM's
  llbuild manifest (`SPMBuildSystem.swift:507-546`), and Bazel dependency
  flags are tokenized from a real `SwiftCompile` action via `aquery`
  (`BazelBuildSystem.swift:393-440`).

## The contract

Two questions, answered per build system, replacing `detect` + `build`:

```swift
public struct Ownership: Sendable {
    public let kind: BuildSystemKind
    public let projectRoot: URL
    public let targetName: String
    public let moduleName: String
    public let markerDepth: Int
}

/// Ownership is ternary, not binary. `indeterminate` (tool missing, describe
/// timed out, project unparseable, generated project stale) must never be
/// folded into `notMember`: an indeterminate nearer marker BLOCKS farther
/// systems and fails the start loudly with its reason, because letting a
/// farther root win on a nearer marker's silence is exactly the D01 silent
/// misattribution this design retires.
public enum OwnershipVerdict: Sendable {
    case confirmed(Ownership)
    case notMember(reason: String)
    case indeterminate(reason: String)
}

public protocol BuildSystemResolver: Sendable {
    /// Claim the file only when this build system's own model confirms the
    /// target membership. No native build may run here; this must stay cheap
    /// enough to call for every candidate marker on the walk.
    func owner(of sourceFile: URL, at candidateRoot: URL) async
        -> OwnershipVerdict

    /// Build the owning target natively, capture its compile command, and
    /// return the full-fidelity context.
    func compileContext(for ownership: Ownership, platform: PreviewPlatform)
        async throws -> CompileContext
}
```

When one build system maps the file to more than one target (multiple Xcode
targets sharing a source; Bazel `rdeps` returning several `swift_library`s —
today's code silently takes `targets.first`, `BazelBuildSystem.swift:274`),
the resolver disambiguates inside one system before the walk compares
systems: prefer a non-test target, honor an explicit target/scheme hint
(mirroring the existing scheme disambiguation at
`XcodeBuildSystem.swift:199-213`), and fail with an `ambiguousTarget` listing
otherwise. SwiftPM alone guarantees disjoint targets.

`CompileContext` supersedes `BuildContext`:

```swift
public struct CompileContext: Sendable {
    public let ownership: Ownership
    /// Semantic swiftc arguments captured from the native build and
    /// normalized (outputs, inputs, and incremental bookkeeping stripped;
    /// defines, language mode, upcoming features, bridging header, plugin
    /// loads, search paths, -package-name retained).
    public let swiftcArgs: [String]
    /// The target's compile inputs as the native build saw them: honors
    /// exclusions, includes generated sources, resolves generated labels to
    /// real paths. Preview file excluded, as today.
    public let sourceFiles: [URL]?
    public let frameworkPaths: [URL]
    public var supportsTier2: Bool { sourceFiles != nil }
}
```

Migration note: `BuildContext` consumers (`PreviewSession.swift:187,242,260`,
`IOSPreviewSession`, watcher wiring in `PreviewStartHandler.swift:328,463`)
switch to `CompileContext`; `compilerFlags` maps to `swiftcArgs`.

## Ownership: nearest confirming root

Replace the fixed system order with a single upward walk from the source file:

1. At each directory level, collect every marker present (`Package.swift`,
   Bazel workspace markers, Xcode project/workspace, and generated-project
   manifests like `project.yml`).
2. For each marker at that level, ask that system's `owner(of:at:)` to confirm
   membership:
   - **SwiftPM**: `swift package describe --type json`, testing the file
     against the target's **resolved `sources` list**, which SwiftPM emits
     post-exclusion (the `Target` struct already decodes it,
     `SPMBuildSystem.swift:307-312`). Not path-prefix-minus-exclusions:
     `describe` has no `exclude` field, and a path-prefix test would over-claim
     files a target's explicit `sources:` omits — the S04 over-inclusion bug
     re-imported into ownership.
   - **Bazel**: existing package-scoped `rdeps` query on the source label
     (`BazelBuildSystem.swift:267-282`); it must stay package-scoped, since a
     broad-universe query loads every package in the workspace
     (`BazelBuildSystem.swift:155-157`).
   - **Xcode**: source membership from the project file(s), which is two
     different mechanisms: classic targets list per-file `PBXBuildFile`
     references (authoritative, predates the build — this is what lets the
     resolver flag a stale project, D07); Xcode 16+
     `PBXFileSystemSynchronizedRootGroup` targets list no files at all, so
     membership there is folder containment minus the
     `PBXFileSystemSynchronizedBuildFileExceptionSet` — a path test, honestly
     weaker, but still scoped by the project's own declared folders. A
     `.xcworkspace` means parsing each referenced project, not one file.
3. The nearest root with a `confirmed` verdict wins. An `indeterminate`
   verdict at a nearer level blocks farther levels and fails the start with
   its reason (fail loud, never guess outward). Same-level tie-break between
   systems is a documented policy: SwiftPM, then Bazel, then Xcode (matches
   today's observable D05 behavior, keeps that guard green).
4. If every marker on the walk is `notMember`, return the collected verdicts —
   the D06 diagnostic becomes "found `project.yml` at X but no generated
   `.xcodeproj`; found `Package.swift` at Y but no target contains this file"
   instead of a generic SwiftPM failure.

`--build-system` keeps its meaning: restrict the walk to that system's
markers, still requiring membership confirmation, still reporting
`notMember`/`indeterminate` reasons as diagnostics.

Cost note: for the winning root the confirmation is dwarfed by the native
build that follows, but disconfirming losers run with no build to hide
behind, and `swift package describe` resolves the package graph each time.
Within one walk, memoize per candidate root; nested-SPM monorepos are the
case that stacks describes. No cross-session caching in v1; ownership
re-resolves per session start, same as today.

## Compile context: capture, interrogate, or re-derive

The decision this document exists for.

**Option A — capture from the real build (recommended).** Run the native
build (already required today), then read the exact compile command the build
system used for the owning target, and transform it:

- **SwiftPM**: read the target's `args:` line from the llbuild manifest at
  `<scratch>/<config>.yaml` — the mechanism `readPackageName` already uses
  (`SPMBuildSystem.swift:507-546`), generalized to return the whole argument
  vector. Verified against the fixtures: the manifest carries every flag the
  current re-derivation drops (`-DSETTINGS_FIXTURE`,
  `-enable-upcoming-feature`, `-strict-concurrency=targeted`,
  `-swift-version`, `-package-name`, and macro-target's
  `-Xfrontend -load-plugin-executable -Xfrontend <host plugin>#<module>`),
  and its source list already honors `exclude:` while including
  plugin-generated and resource-accessor sources. The manifest is written by
  `swift build` even on incremental/null builds, so capture never depends on
  the compile re-running. Expiry risk: SwiftPM's default build system is
  becoming Swift Build, which does not emit this manifest. PreviewsMCP runs
  its own `swift build` (`SPMBuildSystem.swift:347-363`), so it pins
  `--build-system native` near-term; the long-term SwiftPM path converges on
  the same XCBuild/build-description mechanism as the Xcode leg.
- **Bazel**: `bazel aquery 'mnemonic("SwiftCompile", <target>)'
  --output=jsonproto` — same query family the dependency-flag path already
  uses (`BazelBuildSystem.swift:393-440`), pointed at the target itself.
  aquery is static analysis; it also works without the action re-running, and
  its `inputs` resolve generated files to execroot paths (retiring B01's
  workspace-relative guess). The captured command needs Bazel-specific
  pre-processing: it is prefixed `worker swiftc ...`, and its `-sdk` is the
  unexpanded placeholder `__BAZEL_XCODE_SDKROOT__` (aquery never expands it —
  the same reason bazel-compile-commands tooling re-infers `SDKROOT`). The
  Bazel pre-processor strips the driver prefix and DROPS captured
  `-sdk`/`-target`/`-file-prefix-map`, keeping `Compiler`'s own injection and
  the existing `platformFlags` authoritative.
- **Xcode**: build-log parse, decided by the stage-0 spike (run 2026-07-15
  against `xcode-bridging`, Xcode 26.2). The `xcodebuild build` log carries
  the complete `swiftc` invocation on a `builtin-SwiftDriver -- <argv>` line,
  including `-import-objc-header` (the X02 flag), `-D` defines,
  `-swift-version`, and hmap/search paths; the Swift source list is the
  on-disk `@<...>.SwiftFileList` response file it references, and the
  target's ObjC sources appear as `CompileC` lines (the other half X02
  needs). Confirmed weakness: a null build emits zero compile lines. Handling:
  the first capture forces the target's compile by touching one of its
  sources (identity content, so artifacts stay valid), and the parsed command
  is persisted keyed on pbxproj/xcconfig mtimes. Confirmed fallback: the same
  argv strings persist across null builds in
  `DerivedData/.../XCBuildData/*.xcbuilddata/task-store.msgpack`, usable as a
  null-build-stable secondary source (undocumented msgpack;
  reverse-engineering Apple's tooling is an accepted approach here).
  Today's `-showBuildSettings` mapping survives only for artifact locations,
  as elsewhere.

Normalization is two layers, honestly split. A per-system pre-processor
handles what is irreducibly per-system: driver-prefix stripping and
placeholder-bearing flags (`worker`/`-sdk`/`-file-prefix-map` for Bazel,
response-file expansion for Xcode), and the decision of whether captured
`-target`/`-sdk` survive (SwiftPM/Xcode: captured values are real paths and
win; Bazel: dropped, `Compiler`'s injection at `Compiler.swift:76,162,262,325`
and `platformFlags` stay authoritative). Then one shared normalizer applies
the common spec: strip inputs, outputs, output-file-maps, incremental and
driver bookkeeping, diagnostics paths, and module-cache paths; retain
semantic flags (`-D`, `-swift-version`,
`-enable-upcoming-feature`/`-enable-experimental-feature`,
`-import-objc-header`, `-load-plugin-executable`/`-plugin-path`/
`-external-plugin-path` — including their `-Xfrontend`-wrapped spellings —
`-I`/`-F`/`-Xcc ...`, `-package-name`). The shared layer is one auditable
function with one spec; the pre-processors are small and per-system by
necessity, not convenience.

Why A retires the S/X/B rows: the captured command already contains the
conditional define (S02), the bridging header (X02), the macro plugin load
with the host-built plugin path (S05 — SwiftPM builds the plugin executable
as part of the native build; today it is simply never referenced), the
xcconfig-injected settings for the selected configuration (X01), and the
plugin-generated inputs with exclusions applied (S01/S03/S04, from captured
inputs rather than a directory scan).

**Option B — interrogate structured tool output** (`swift package
describe`/`dump-package`, `-showBuildSettings`, `bazel query
--output=build`) and map each setting to flags ourselves. This is today's
architecture, extended. Every regress verification pass so far has found a
setting the mapping missed; the catalog is open-ended by construction (SwiftPM
alone: unsafe flags, C settings, plugin outputs, language modes, package
access level...). Interrogation stays the right tool for *ownership* and for
locating artifacts, and it is the Xcode fallback, but it should stop being the
source of compile-command truth.

**Option C — keep the current per-system re-derivation.** Known-failing on
11 reproduced rows; listed only for completeness.

Recommendation: **A**, with B retained where it is already correct (ownership
queries, artifact locations) and as the Xcode fallback. Risks and their
mitigations:

- *Captured commands embed absolute and ephemeral paths.* The normalizer
  strips module-cache/temp paths and keeps project-absolute ones; fixture
  coverage exercises this per system.
- *Xcode null builds emit no compile command.* Confirmed by the spike, and
  handled: force the first capture with a source touch, persist it keyed on
  project-file mtimes, with XCBuildData's `task-store.msgpack` verified to
  hold the same argv as a null-build-stable secondary.
- *Manifest/aquery formats drift with toolchain versions.* They are more
  stable than the settings catalog they replace (llbuild manifest format and
  aquery jsonproto are machine interfaces), and the regress matrix is the
  drift detector for format changes. The one scheduled break — Swift Build
  replacing the llbuild manifest — is handled proactively by pinning
  `--build-system native` on our own `swift build`, not reactively.
- *`swiftc -v` / driver-plan divergence between the native driver invocation
  and our frontend usage.* Already handled once in `Compiler.swift:351`
  (`-###` re-parse); the normalizer owns this translation in one place.

## Implementation stages, each ending in a manual matrix pass

Integration tests are explicitly deferred; each stage's exit criterion is a
manual re-verification of its rows with the Bazel-built CLI (isolated
`PREVIEWSMCP_SOCKET_DIR=/tmp/pmcp-*`, PNG snapshots read directly), flipping
rows Reproduced→Guard in `VERIFICATION.md` with dated entries.

0. **Capture spikes** (throwaway, one per system): prove the full argument
   vector is recoverable — `spm-settings` (S02) **and** `macro-target` (S05:
   the `-load-plugin-executable` flag only appears there; `spm-settings` uses
   a build-tool plugin, not a macro), `bazel-bzlmod` (B01), `xcode-bridging`
   (X02). Exit: captured args contain the known-dropped flag for each.
   DONE 2026-07-15 for all three systems: SwiftPM and Bazel verified during
   design review, Xcode verified by the log-parse spike above.
1. **Ownership walk + declines** (D-family): implement `owner(of:at:)` for
   all three systems, replace `BuildSystemDetector` order with the
   nearest-confirming walk, wire declines into the start-failure message.
   Re-verify D01–D09 (expect D01/D03/D04/D07/D08 flip; D06 flips to the
   diagnostic contract; D02/D05 stay green; D09 needs the identifier
   sanitizer below). X02's detection half flips here.
2. **SwiftPM capture** (S-family): llbuild-manifest capture + input-derived
   source list + normalizer v1. Re-verify S01–S06 (expect S01–S05 flip) and
   re-run W01 as a no-regression check on hot reload. D09's module-name
   sanitizer (deterministic mangling of non-identifier characters) lands
   here.
3. **Xcode capture** (X-family): chosen mechanism + normalizer reuse.
   Re-verify X01, X02, D08, R03 (generated sources half), W-rows touching
   Xcode none. Expect X01/X02/D08 flip; R03 partial.
4. **Bazel capture** (B-family): target-level aquery capture. Re-verify B01,
   B02, B03 (expect flips), B04/F01 (staging/classification remain open,
   different family).

Stages 2–4 are independent once 0–1 land; order by row count (SwiftPM first).
Each stage is its own PR through the usual gates (/simplify, /code-review,
full local suite, `merge` label).

## Out of scope

- Watching/invalidation (W04, C03–C05): the captured input list is handed to
  the watcher as an enabler, but invalidation ownership rules are the next
  design.
- Runtime staging of framework resources (B04), slice classification (F01),
  phase/heartbeat protocol, semantic interaction.
- Caching `CompileContext` across sessions: explicitly not in v1; capture
  cost is bounded by the native build that already runs.

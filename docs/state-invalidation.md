# State Invalidation: derived state carries its evidence

Status: DRAFT for review — 2026-07-15

PreviewsMCP derives state from the filesystem and from child processes — a
config-discovery result, a captured compile command, a watch set, a staged
resource bundle, a device→agent binding — and then holds that state for the
lifetime of a daemon or a session with no record of what it was derived from.
When the world moves (a config file appears or is deleted, a dependency source
is edited, a project is regenerated, an agent crashes, a device is reclaimed
by a second session), the derived state is silently wrong: stale traits, stale
renders, phantom sessions, and success responses for operations that reached a
dead process. This is the root cause of 7 reproduced rows in
`examples/regress/VERIFICATION.md` plus the live-session residue of D07.

The fix is one ownership rule applied everywhere: **every piece of derived
state has exactly one owner, the owner keeps the evidence the state was
derived from, and when the evidence changes the state is re-derived through
the path that produced it — never patched, never trusted stale.** Evidence
comes in two shapes. Filesystem evidence (paths, mtimes, watched files) is
revalidated on read or watched for change, and invalidation re-runs the
producer (the walk, the native build, the capture). Process evidence (agent
channel, device claim) is checked at every consuming entry point, and
transitions — crash, respawn, replacement — are disclosed in tool responses,
never absorbed as log lines.

## Matrix rows this retires

| Cluster | Rows | Shared root cause |
|---|---|---|
| Config discovery cached forever | C03, C04, C05 | `ConfigCache` memoizes the walk result per directory for the daemon's lifetime with no evidence attached (`PreviewsEngine/ConfigCache.swift:7-21`); a nearer config appearing, an in-place edit, and a deletion are all invisible |
| Watch set is a subset of the evidence; producers never re-run | W02, W04 (#415), D07 residue | The watch set is the preview file plus the captured **target** Swift sources only (`PreviewStartHandler.swift:328`, `HostApp.swift:93`); `SPMCommandCapture` drops non-Swift inputs (`SPMCommandCapture.swift:46-47`); `buildContext` is immutable for the session's life (`PreviewsCore/PreviewSession.swift:91`, `PreviewsIOS/IOSPreviewSession.swift:29`); a structural reload re-runs Tier 2 `swiftc` only — the native build, capture, and resource staging never re-run (`HostApp.swift:151-157`, `IOSPreviewSession.swift:662-663`) |
| Session liveness assumed | L01, L04 | No device→session ownership: a second start on the same device SIGKILLs the incumbent's agent behind its back (`IOSPreviewSession.swift:282-288`) and leaves the zombie registered (`IOSSessionManager.swift:43-57`); out-of-band agent death respawns silently (#253, `IOSPreviewSession.swift:405-424`) with failures printed to stdout instead of the log (`:422`); `touch` returns success without any liveness round-trip (`PreviewTouchHandler.swift:94-99`) |

Guards that must keep passing: W01, W03 (atomic saves), L05, D07's
start-time diagnosis, R02, M02, and the daemon-liveness half of L02 (its
message opacity belongs to the phase/error family).

Not addressed here (separate families): thunking (C01/C02/V02), phase/error
protocol (F01, R01, T01, T03, L02, L03, P01), semantic interaction (I01–I03).
The crash disclosure designed below is deliberately minimal; the phase/error
protocol family will later fold it into its classified error taxonomy.

## Today's shape (evidence)

- `ConfigCache` is a daemon-lifetime `[directory: Result?]` actor
  (`PreviewsEngine/ConfigCache.swift:7-21`). Consumers: `preview_start`
  (`PreviewStartHandler.swift:143`) and the per-snapshot quality lookup
  (`MCPServerSupport.swift:147`). The underlying walk is one read attempt per
  ancestor directory (`PreviewsCore/ProjectConfig.swift:59-71`) — microseconds
  against consumers that compile Swift or encode a PNG.
- The session watch set is `[previewFile] + buildContext.sourceFiles`, wired
  once at start on both platforms (`PreviewStartHandler.swift:328-346` for
  iOS, `HostApp.swift:83-103` for macOS). `FileWatcher` installs FSEvents
  streams on the parents but the trampoline filters fired paths against the
  exact canonical file set (`FileWatcher.swift:84`), so resources, manifests,
  project files, dependency sources, and **newly added files** can never fire.
- A watcher burst classifies as unchanged/literal/structural
  (`PreviewSession.swift:505`); structural re-runs Tier 2 compilation against
  the session's frozen `buildContext`. Dependency `.swiftmodule`s, staged
  resource bundles, and the captured command itself are consumed as they were
  at session start.
- The captures already enumerate most of the missing evidence and throw it
  away: SwiftPM's llbuild manifest carries every target's compile node and
  inputs in one file (`SPMCommandCapture.swift:11-17` reads one node, filters
  to `.swift`); Xcode's persisted capture already computes the definition-file
  evidence set — referenced pbxprojs + xcconfigs with mtimes — to key capture
  validity across **starts** (`XcodeCommandCapture.swift:93`), but no live
  session watches those files; Bazel's aquery jsonproto parse loops over
  `SwiftCompile` actions already (`BazelCommandCapture.swift:35-41`);
  today's query returns only the target's, and enumeration widens the query
  to `deps(target)`.
- iOS lifecycle: `IOSSessionManager` is a flat `[id: session]` map with no
  device index (`IOSSessionManager.swift:12`). `preview_start` resolves a
  device and launches; the pre-launch "terminate stale agent + shell"
  (`IOSPreviewSession.swift:282-288`) is device-scoped, so it kills whatever
  session currently owns the device. The incumbent's death watcher then races
  the new launch with a respawn (`IOSPreviewSession.swift:410`). `elements`
  does round-trip the channel (`IOSPreviewSession.swift:796-806`), but `touch`
  is fire-and-forget and unconditionally reports success
  (`PreviewTouchHandler.swift:94-99`).

## Design

### Config discovery: delete the cache (C03–C05)

Remove `ConfigCache` and call `ProjectConfigLoader.find` at each consumer.
The cache memoizes a handful of `stat`/read syscalls for callers whose own
cost is milliseconds to minutes; it is derived state with no evidence, and
the cheapest correct owner of "which config applies" is the filesystem
itself. C03 (nearer config appears), C04 (in-place edit), and C05 (deletion,
fall back to parent) all become trivially correct because every lookup is a
fresh walk and a fresh decode.

Alternative rejected: an evidence-keyed cache (validate every probed ancestor
path plus the found file's mtime/size on each read). Validation performs the
same syscalls as the walk, so the cache would only memoize the JSON decode.
That is complexity with no measurable win. The repo's precedent for
evidence-keyed caching, `SetupCache` (`SetupCache.swift:120-169`), earns its
keep because re-derivation there is a full package build; config
re-derivation is a stat walk, so the same pattern buys nothing.

Unchanged by design: a **running** session reads its config once at start
(documented at `PreviewStartHandler.swift:139-141`). The C rows only require
that the next start or the next quality lookup sees the filesystem, and after
this change they do.

### Watch set = captured evidence; evidence changes re-run the producer (W02, W04, D07 residue)

The resolver made the native build's own output the source of truth for the
compile command. This stage extends the same principle in time: the capture's
input enumeration becomes the watch set, and a change to any of it re-runs
the producer chain that consumed it.

**EvidenceSet.** Each capture returns, alongside the compile command:

- `targetSources` — already captured today.
- `sourceDirectories` — the source roots of the target and its local
  dependencies. This is the load-bearing category: it is what makes file
  **addition/removal** visible (a per-file watch list cannot see a new
  file), and directory scope means dependency source *files* need not be
  carried as their own category — an edit under a dependency's root fires
  the directory match. Root derivation per system: SwiftPM from the target
  directories of the other `C.*` compile nodes in the same llbuild manifest
  (one file, already parsed; verified against the W04 fixture — the App's
  `debug.yaml` enumerates `C.SharedLocal`'s sources); Bazel from the
  sources of dependency `SwiftCompile` actions by widening the existing
  aquery to `mnemonic("SwiftCompile", deps(target))` (verified against the
  B01 fixture, same jsonproto shape — the existing parse already loops
  `SwiftCompile` actions, `BazelCommandCapture.swift:35-41`), each source
  realpath-classified per the exclusion rule before its root is taken;
  Xcode from the project's target group roots (synchronized-group roots
  where used). Named caveat: an Xcode source reachable only through an
  old-style file reference with no enclosing group root (the X01
  referenced-project shape) has no directory representation and keeps
  today's behavior.
- `runtimeInputs` — resource files, best-effort per system; a miss degrades
  to today's behavior (not watched). SwiftPM: the inputs of `copy-tool`
  nodes in the llbuild manifest (verified against the W02 fixture; take the
  `copy-tool` nodes' inputs, not the aggregate `module-resources` node,
  whose inputs are staged products under `.build`). Xcode: scoped out with
  a named limitation — incremental build logs omit `CpResource` lines for
  unchanged resources (the same null-build property that forced the
  off-disk clang-object read in stage 3 of the resolver), so there is no
  reliable start-time enumeration. Bazel: scoped out — resource inputs ride
  in depsets, not in `arguments`, and resolving them is new machinery for a
  row family that has no Bazel-resource reproduction.
- `definitionFiles` — `Package.swift`/`Package.resolved`; the referenced
  pbxprojs + xcconfigs (exactly the set `XcodeCommandCapture` already
  enumerates for persistence keying, `XcodeCommandCapture.swift:98`); the
  XcodeGen manifest when one sits beside a generated project (D07). Bazel:
  `MODULE.bazel` plus the `BUILD` file of the owning package; transitively
  loaded `.bzl` files are scoped out (a different query, no reproduced row
  needs them).

**Exclusion rule.** Every captured path is realpath-normalized, then
classified: a path is **product** (excluded) when it resolves under `.build`,
DerivedData, `bazel-out`, or Bazel's output-base/cache area, and **evidence**
(watched) when it resolves inside the workspace. The resolution step is
load-bearing for Bazel: aquery spells a `path_override` local dependency's
sources as `external/<repo>+/…`, which realpaths back into the workspace —
the Bazel analog of W04 — while a fetched dependency's sources realpath into
the cache and are correctly excluded. A naive "exclude `external/`" would
drop exactly the sources W04 needs (and FSEvents reports canonical paths, so
an unresolved `external/…` entry could never match a fired event anyway).
Products are excluded even when captured as compile inputs (e.g. SwiftPM's
generated `resource_bundle_accessor.swift` under `.build`): their
generators' inputs are the evidence, and watching products would feed
rebuild loops — the native build we trigger would fire the watcher that
triggered it. Named limitation: a build-tool plugin whose input lives
outside the package's watched directories can go stale; that input is not
enumerable from any build system's model.

**FileWatcher.** Gains directory-scoped entries: in addition to the exact
canonical path set, a fired path matches when it lies under a watched
directory and has a watched extension (`.swift` for `sourceDirectories`).
FSEvents streams are recursive per root, so a directory entry becomes a
stream root alongside today's parent directories
(`FileWatcher.swift:90-99`); the trampoline filter adds a prefix+extension
match next to the exact-path match (`FileWatcher.swift:84`). W03's
canonical-path rename handling is unaffected for the exact-path set.
Stream-root hygiene: never install a root that contains a build-product
directory — a package declared with `path: "."` puts `.build` inside the
package root, and FSEvents cannot exclude a subtree of a root, so every
object file written by the very build tier 1 triggers would be delivered to
the trampoline (filtered, but a CPU firehose). Watch the target's `Sources`
subdirectories as roots, never the package root.

**Tiered burst classification.** The existing
unchanged/literal/structural classification (`PreviewSession.swift:505`)
stays as-is for bursts confined to the primary file and `targetSources` —
W01/W03 guard behavior is untouched. Two tiers sit above it:

1. Burst touches `runtimeInputs`, or a path under any `sourceDirectories`
   root that is not an already-captured target source (a file added to or
   removed from the target itself also invalidates the captured source
   list, so the target's own root participates; only edits to existing
   `targetSources` stay on the fast path) → **refresh**: re-run the native
   build through the same build system that ran at session start (rebuilds
   dependency swiftmodules, restages resource bundles), re-capture, swap
   the session's compile context and reinstall the watcher from the new
   EvidenceSet, then structural reload. W04's healthy result — "watch
   dependency sources and rebuild the dependency module before reload" —
   is exactly this tier; likewise W02's "rebuild/restage affected runtime
   inputs without a daemon restart".
   The **entire** refresh — native build through reload — runs under the
   session's serialized entry-point mutex, and a burst arriving mid-refresh
   marks the session dirty **at the highest tier observed** so one
   follow-up runs after at that tier (a definition-file change landing
   mid-refresh must not be downgraded to a plain rebuild — it still owes
   the re-resolve below). iOS already has the mutex — the render lock +
   `recovering` coalescing (`IOSPreviewSession.swift:141,411-413`), whose
   hold widens to cover the build and capture steps; macOS has no
   equivalent today and gains one. Cross-session build exclusion on a
   shared project root is delegated to the build tools' own build-directory
   locks (SwiftPM refuses concurrent use of one `.build`; Bazel serializes
   on the output base) rather than a new cross-session lock of ours — L05
   already drives two concurrent starts against one package and passes.
   Stage 4's manual pass drives two co-rooted sessions through a shared
   dependency edit to confirm the delegation holds.
   Loop damping is lazy and scoped to fired paths: the first fire of a
   path records its content hash (reusing `SetupCache`'s per-file SHA256
   shape, `SetupCache.swift:41-101`); a subsequent fire whose content
   hashes to the recorded value is dropped without re-deriving, and a real
   change updates the record. Normal sessions therefore hash nothing until
   a burst arrives, and only the burst's files ever. This makes a
   deterministic in-tree generator (a build step that rewrites a generated
   `.swift` inside a watched source root with identical content) converge
   after one refresh instead of looping; a **nondeterministic** in-tree
   generator (embedded timestamps) would still self-trigger and is a named
   limitation — build-tool outputs belong under `.build`, where the
   product exclusion already drops them.
   iOS resource restaging: the native build restages into the host `.build`,
   but the agent reads `Bundle.module` from the app container installed in
   the simulator, so the refresh must push the rebuilt bundle into the
   container (path via `simctl get_app_container`), falling back to an agent
   relaunch if the in-place copy proves insufficient — verified either way
   during stage 4.
2. Burst touches `definitionFiles` → **re-resolve**: re-run the ownership
   walk first (a regenerated or newly-stale project re-diagnoses through the
   D07 path; a target that no longer owns the file becomes a classified
   session error instead of a stale render), then proceed as tier 1.

`buildContext` changes from `let` to a private, session-owned replaceable
value with one update entry point per platform session; the watcher swap
reuses the existing stop-and-replace path (`HostApp.swift:95-96`,
`IOSSessionManager.setFileWatcher`). The seam for the new tiers is
`classifyWatchedChange` (`PreviewSession.swift:492-497`) — it already
receives the fired-path burst and owns the primary-vs-secondary
discrimination; the tiers widen its secondary-file branch, and the
single-file content diff below it (`classifySourceChange`,
`PreviewSession.swift:505`) is untouched. Both platforms share the widened
classifier in `PreviewsCore`; the reload executors stay platform-specific,
as today.

Cost accepted: a dependency or resource edit now costs one native build.
That is the same step every session start already runs, and it is what Xcode
Previews itself pays per edit. Alternative rejected: compiling dependency
sources into the preview dylib to avoid the native build — that re-implements
the native build's semantics, which is the defect family the resolver just
eliminated. Also accepted: the refresh always ends in a structural reload
even when the rebuild changed no module interface (a comment-only dependency
edit pays the full reload); the reliable gate would be a module-interface
diff across three build systems, recorded as a future optimization, not
designed here.

Instrumentation note: W02's reproduction recorded a "reload transition" on a
resource-only edit even though a resource path cannot pass today's trampoline
filter (`FileWatcher.swift:84`). Root-cause that observation while
implementing tier 1 — it may indicate an editor-burst side effect worth a
regression note in VERIFICATION.md.

### Device claim and crash disclosure (L01, L04)

**L01 — the device is an exclusive resource with one owner.**
`IOSSessionManager` gains a `deviceUDID → claim` reservation, maintained
with the session map. A claim is a small state machine — `claiming` →
`live` → `stopping` — because the manager is an actor but "claim, then
build and launch" spans a long `await`: without states, a concurrent start
on the same device would replace an incumbent whose `start()` is still
running, manufacturing exactly the half-launched zombie L01 describes. The
rules: a start registers a `claiming` reservation before building or
launching anything; a start that finds an existing claim **awaits it
reaching a stoppable state** (`live`, or `claiming` resolved either way),
then deterministically **replaces** — stopping the incumbent through
`IOSPreviewSession.stop()`, which sets `stopping` and thereby suppresses
the death-watcher respawn (`IOSPreviewSession.swift:411,417`) — removes it,
republishes the registry, and proceeds; and a start re-checks that it still
holds the claim after its own `start()` returns, deregistering itself if it
was replaced while launching. The new session's start response discloses
`replaced session <id> on this device`. This turns the current implicit
kill (`IOSPreviewSession.swift:282-288` SIGKILLs the incumbent's agent
while its session object lives on) into an ordered ownership transfer; the
pre-launch terminate remains as a belt for agents from crashed daemons.
Replace was chosen over fail-fast: it matches the effective current
behavior, satisfies the row's "deterministically replace or fail fast
without a timeout", and does not force the client to hunt down a session it
may not know about. L05 (two simultaneous starts) is the guard that catches
a botched reservation.

The claim is per-daemon, but the device is a cross-process resource and the
belt terminate is device-scoped — a second daemon would SIGKILL a live
incumbent owned by the first. So `SessionRegistry.Entry` gains a
`deviceUDID` field, and claiming consults `readOthers()`: a session on the
target device published by a **live** foreign process is a classified
fail-fast error naming that session and its owning pid (a foreign session
cannot be stopped in an ordered way, so replacement stays within-process).
The belt terminate runs only after the cross-process check comes back
clear, so it only ever hits agents orphaned by dead daemons — which is what
it was for. Named limitation: the cross-process check is
read-before-publish, so two daemons starting on one device at the same
moment can both pass it — closing that window needs a per-device
cross-process lock (flock in the registry dir), deferred until a row
reproduces the race.

**L04 — agent death is a session-state transition, not a log line.**

- The death watcher records a crash incident (monotonic count, wall time)
  on the session before attempting respawn; a failed respawn moves the
  session to a terminal `failed` state. Both paths log via `Log.error` —
  today the failure goes to stdout (`IOSPreviewSession.swift:422`) and is
  invisible in `serve.log`.
- Agent-bound operations that claim success become acknowledged
  round-trips: `touch`/`switch`/`configure` use the channel's existing
  request/response path (`sendAndAwait`, as `elements` already does,
  `IOSPreviewSession.swift:802`) instead of fire-and-forget `send`. A
  throwing send on a disconnected channel is kept as a backstop but does
  not close the crash window by itself — in the interval between the agent
  dying and the socket noticing, `isConnected` is still true and a write
  into the dead socket's buffer succeeds; only a missing acknowledgment
  detects that interval.
- Session-scoped handlers surface an undisclosed incident in their next
  response: "the preview agent crashed and was relaunched; UI state was
  reset." Two constraints are normative here; the concrete carrier (content
  position, `structuredContent` field, uniformity across handlers) is owned
  by the phase/error-protocol family's response taxonomy and gets its final
  shape there. First, the notice must not displace or amend `content[0]`,
  which clients parse as raw JSON in `elements`
  (`PreviewElementsHandler.swift:80`). Second, the incident is cleared only
  when a response actually **carried** the notice, not when it was merely
  eligible — `elements` builds `structuredContent` conditionally
  (`PreviewElementsHandler.swift:68-77`), and a disclosure that rode only a
  nil structure would be silently lost. A `failed` session returns a
  classified error on every call. This is the row's "report the failure and
  preserve daemon liveness": the daemon never dies, and no caller can
  mistake a crash-reset session for the one they were interacting with.

macOS's JIT agent shares the ownership pattern but has no reproduced row;
it adopts the same incident surface only if a row ever reproduces there.

## Implementation stages, each ending in a manual matrix pass

Stages follow the resolver discipline: design → implement → gates
(/simplify, /code-review, unit tier, integration tier) → manual matrix
re-verification flipping rows in VERIFICATION.md before the next stage.

1. **Config discovery invalidation (C03, C04, C05).** Delete `ConfigCache`,
   walk at each consumer. Unit: existing config tests keep passing; the
   quality lookup path gets a fresh-read test. Manual: C03/C04/C05 flip.
2. **Device claim + crash disclosure (L01, L04).** Manager-owned device
   reservation (`claiming`/`live`/`stopping`) with ordered in-process
   replacement and the cross-process registry check (`deviceUDID` on
   `SessionRegistry.Entry`); crash incidents, acknowledged agent
   round-trips, disclosure appended as the last content item and cleared
   only on delivery. Unit: claim replacement and incident bookkeeping under
   the contended paths (start-B-while-A-still-starting, replacement during
   launch, death-during-touch). Manual: L01/L04 flip; L05 and L02's
   daemon-liveness half hold.
3. **EvidenceSet capture.** Extend the captures to enumerate
   `sourceDirectories`, `runtimeInputs`, `definitionFiles` per the scoping
   above; carry the set on `BuildContext`; log it at session start for
   verifiability. Effort is uneven by system: SwiftPM is a widening of the
   existing manifest parse (verified); Bazel roots come from a query
   widening plus the realpath classification; Xcode roots come from the
   project model, and Xcode/Bazel `runtimeInputs` are scoped out.
   Unit-tested per system against the regress fixtures. No behavior
   change: W rows still reproduce, all resolver guards (S, X, B, D rows)
   hold.
4. **Tiered invalidation (W02, W04, D07 residue).** Directory-scoped
   watcher matching with the realpath exclusion rule, lazy fired-path hash
   damping, the widened `classifyWatchedChange` tiers, whole-refresh hold
   of the per-session mutex carrying the highest observed tier (native
   rebuild + re-capture + context/watcher swap), iOS bundle push into the
   app container, then reload. Manual: W02/W04 flip (#415 closes), D07
   residue exercised by regenerating the project mid-session, W01/W03
   guards hold, and two co-rooted sessions through a shared dependency
   edit confirm the build tools' own locks serialize the concurrent
   rebuilds.

Stages 1 and 2 are independent of 3→4 and of each other; 3 must land before
4, mirroring the resolver's capture-then-consume order.

## Out of scope

- Live re-read of `.previewsmcp.json` for running sessions (read-once at
  start is documented behavior; no matrix row demands otherwise).
- `@State` preservation across tier-1/2 refreshes — a structural reload
  resets live state by design; the refresh tiers inherit that.
- The phase/error protocol family (F01, R01, T01, T03, L02, L03, P01 and
  the heartbeat surface): the crash disclosure here is the minimal slice
  L04 needs and will be re-expressed in that family's error taxonomy.
- Watcher coverage for standalone sessions (no build context): they keep
  today's primary-file-only watch.

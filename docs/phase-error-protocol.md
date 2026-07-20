# Phase and Error Protocol: every phase owns its outcome

Status: DRAFT for review — 2026-07-16

A preview operation is a pipeline of long, failable phases — detect, native
build, capture, setup build, bridge compile, JIT link, setup run, render,
snapshot — but the pipeline's outcome protocol is partial. Progress fires
only when a phase *starts*, so a long phase is indistinguishable from a hung
one (an 8-second render, an 11.8-second build, an 8-second setup all run in
total silence). Failures collapse: the JIT's real symbol dump goes to the
daemon log while the caller gets a generic materialization wrapper; a native
build's incompatible-XCFramework failure surfaces as raw compiler stderr; a
thrown error of any domain type flattens to `internalError(localizedDescription)`
at the JSON-RPC boundary. And a phase can silently not run at all: a
configured preview setup is dropped without a word whenever the Tier 2 split
is unavailable, and the start reports success. This is the root cause of 7
reproduced rows in `examples/regress/VERIFICATION.md`.

The fix is one protocol rule applied everywhere: **the response owns the
phase protocol — a running phase ticks its elapsed time to the caller, a
failing phase names itself and its cause, and a skipped phase is disclosed.
`serve.log` receives a copy; it is never the only record of a phase
outcome.**

## Matrix rows this retires

| Cluster | Rows | Shared root cause |
|---|---|---|
| Silent long phases | L03, P01, T03 (heartbeat half) | `ProgressReporter.report` is called once per phase boundary (`MCPServerSupport.swift:23-44`); the long work runs inside a single `await` with no elapsed-time observer — the subprocess runner returns child output only at exit (`AsyncProcess.swift:303-326`) and its only timer is the timeout explicitly banned for builds (`AsyncProcess.swift:120-123`); the render entry is one blocking call (`JITStructuralReloader.swift:126-131`) |
| Collapsed failures | L02, R01, F01 | No custom ORC error reporter: LLVM's `Symbols not found: [...]` goes to the ExecutionSession's default stderr reporter (daemon log) while `lookup` returns only the flattened `Failed to materialize` wrapper (`PreviewsJITLinkCxx.cpp:261-265,306-322`; the remote-session builder every render uses, `createRemoteSessionFromFDs` at `:360-450`, installs no reporter); native-build stderr flows unclassified through `BuildSystemError.buildFailed` (`SPMBuildSystem.swift:481-499`, `BuildSystem.swift:151-175`) into `"Project build failed: ..."` (`PreviewStartHandler.swift:308-314`); any other thrown error flattens at `PreviewsMCPServer.swift:158` |
| Silently skipped phase | T01, T03 | `hasSetup` requires the Tier 2 split context (`PreviewSession.swift:209-211`), so a single-source target — the setup-faults fixtures' exact shape — drops the configured setup entirely: no dylib, no `previewSetUp`, no `wrap`, no warning (verified 2026-07-16, below); when setup *is* wired, a thrown `setUp()` is swallowed by `try?` inside the agent (`BridgeGenerator.swift:516`) against the documented warning contract (`PreviewsSetupKit/PreviewSetup.swift:26-27`, `docs/setup-plugin.md:12`) |

Also folded in (deferred here by `docs/state-invalidation.md:336,399-402`):
the crash-disclosure carrier's final shape, and the classified ownership-loss
session notice (today a log line + keep-preview,
`HostApp.swift:219-225`, `IOSPreviewSession.swift:738-743`).

Guards that must keep passing: T02 (`Setup package '<X>' build failed`,
`SetupBuilder.swift:298-299`), L01/L04/L05 (device claims and crash
disclosure round-trips), M02, D06/D07 start diagnostics, V05, W01–W04, and
every resolver row. `RegressGuardTests` pins guaranteed message tokens for
the error rows — any migration of an existing message onto the new carrier
must preserve its pinned tokens (or update the guard in the same stage,
never across stages).

Not addressed here (separate families): thunking (C01/C02/V02), semantic
interaction (I01–I03), resource staging (B04/R02/R03).

## Today's shape (evidence)

- **Progress is step-boundary only.** `MCPProgressReporter.report` emits one
  `[step/total]` log line per phase entry, plus an MCP `ProgressNotification`
  only when the caller supplied a `progressToken`
  (`MCPServerSupport.swift:23-44,53`). The CLI never sends a token
  (`PreviewsMCPClient.swift:83-87`); its only progress channel is the
  `logger:"preview"` log notification bridged to stderr
  (`DaemonClientChannel.swift:23-30`). Nothing anywhere observes elapsed
  time during a phase; the "silent intervals" the matrix recorded are the
  timestamp gaps between two boundary log lines.
- **Two error conventions, one flattener.** Handlers either return
  hand-built `CallTool.Result(content:[.text(...)], isError:true)` with
  ad-hoc interpolated strings (`PreviewStartHandler.swift:184-186,308-314`,
  `PreviewElementsHandler.swift:40-66`) or throw domain errors that
  `PreviewsMCPServer.complete` flattens to
  `MCPError.internalError(localizedDescription)` — full detail to the log,
  type identity gone (`PreviewsMCPServer.swift:143-163`). The CLI carrier is
  a string (`DaemonToolError.swift:12-20`). Domain enums with good messages
  exist (`BuildSystemError`, `SetupBuilderError`, `IOSPreviewSessionError`,
  `DaemonClientError`) but nothing preserves them across the boundary.
- **The L02 split.** The JIT engine installs no ExecutionSession error
  reporter, so ORC's underlying `Symbols not found: [ _sym ]` prints to
  stderr (the daemon log) while the error returned from `lookup` is the
  flattened top-level wrapper naming only `renderPreviewToFile`
  (`PreviewsJITLinkCxx.cpp:261-265,306-322`). The LLJIT that materializes
  every render is built daemon-side in `createRemoteSessionFromFDs`
  (`PreviewsJITLinkCxx.cpp:360-450`) — on **both** platforms: macOS reaches
  it through the spawned-agent socketpair (`:484`) and iOS through the
  agent channel's fd (`previewsmcp_jit_remote_session_create_from_fd`,
  `:488-491`, via `JITSession(remoteFD:)`,
  `PreviewsJITLink.swift:124-133`); the sim-side app hosts only the EPC
  executor. (The in-process JIT built by `makeJIT`, `:237-258`, is not on
  the render path — its `runOnMain` refuses without a remote session.)
  Downstream wrappers coarsen further:
  `JITReloadError.renderFailed(status:)` drops all context
  (`JITStructuralReloader.swift:126-131`), and iOS `enrichedJITFailure`
  replaces the error with `jitExecutorFailed(stage:code:)`
  (`IOSPreviewSession.swift:611-618`) — but that channel carries executor
  *lifecycle* failures (#217), not materialization errors, which never
  leave the daemon process.
- **Setup is dropped by the split gate.** Verified 2026-07-16 against the
  T03 fixture with the Bazel-built CLI: as shipped (single source file),
  `run` returned ~3s after the compile line, the daemon logged
  `add-deps dylibs=0`, `render-entry 89ms`, and the snapshot carried no
  `wrap` overlay — setup never built into the render at all. The same
  fixture with one extra source file in the app target: `run` blocked ~9s
  after the compile line, `add-deps dylibs=1`, and the snapshot rendered the
  fixture's "slow setup completed" overlay. Mechanism: `hasSetup =
  splitContext != nil && isUsableSetup(...)` (`PreviewSession.swift:209-211`)
  where `splitContext` requires non-empty Tier 2 sources — and captured
  inputs exclude the preview file itself, so a single-file target yields
  none; the no-bulk compile branch also omits `setupCompilerFlags`
  (`PreviewSession.swift:301-310`). Consequences: T03's recorded "run
  returned before setup finished" is the silent drop, not an ordering
  defect — when setup is wired, the render entry runs it to completion
  before returning (the semaphore bridge, `BridgeGenerator.swift:509-522`,
  under the synchronous EPC call, `PreviewsJITLinkCxx.cpp:511-531`). T01's
  fixture never ran its throwing `setUp()` either; and even wired, the
  throw would vanish into `try? await` (`BridgeGenerator.swift:516`).
- **F01 is classifiable but unclassified.** No component reads an
  `.xcframework/Info.plist`; slice selection is delegated to the native
  build, whose `no such module 'BadSlice'` stderr flows through
  `buildFailed` verbatim. The fixture's plist names exactly what a
  classified error needs: one `AvailableLibraries` entry,
  `LibraryIdentifier: ios-arm64`, `SupportedPlatform: ios`, and no
  `SupportedPlatformVariant: simulator` entry.
- **Disclosure carriers exist but are ad hoc.** The crash notice rides as a
  trailing content item via `appendingIncidentNotice`
  (`MCPServerSupport.swift:162-171`) with two normative constraints already
  established (`docs/state-invalidation.md`): never displace `content[0]`
  (raw JSON in `elements`, `PreviewElementsHandler.swift:86-92`), cleared
  only on actual delivery. The start response has a `setupWarning` field
  populated only for standalone mode (`DaemonProtocol.swift:67`,
  `PreviewStartHandler.swift:193-196,226`; iOS hardcodes nil at `:399`).
  Hazard, two-sided, branching on the `elements` CLI's `--json` flag
  (`ElementsCommand.swift:42,85`): the default path joins **all** text
  items to stdout (`ElementsCommand.swift:95-98`,
  `MCPContentHelpers.swift:8-13`), so a trailing notice is shown but
  concatenated onto the accessibility-tree JSON — corrupting piped
  consumers; the `--json` path emits `structuredContent` only
  (`ElementsCommand.swift:91`) and ignores text items, so there the
  notice is consumed by attach-and-clear yet never shown.

## Design

### Classified failures: `PhaseFailure`

One error carrier for everything a phase can fail with, defined in
`PreviewsCore` beside `BuildPhase`:

```swift
public struct PhaseFailure: Error, Sendable {
    public let phase: BuildPhase
    public let code: FailureCode
    /// One-line classification. Stable tokens: guards pin identifiers and
    /// commands from this line, never connective prose.
    public let message: String
    /// Bounded raw evidence: the compiler stderr tail, the symbol list.
    public let detail: String?
    /// The actionable next step, when one is known.
    public let remediation: String?
}

/// Only codes a designed flow actually produces; a case is added when a
/// migration reaches it, never speculatively.
public enum FailureCode: String, Sendable {
    case buildFailed          // native build failure (F01's base)
    case incompatibleSlice    // F01
    case unresolvedSymbols    // L02, R01
    case sessionFailed        // the terminal failed session state (L04)
}
```

Formatting happens in exactly one place. A `PhaseFailure` becomes
`CallTool.Result(isError: true)` whose `content[0]` text is
`"<phase> failed: <message>"` followed by the bounded detail and the
remediation, and whose `structuredContent` carries
`{"error": {"phase", "code", "message", "detail", "remediation"}}` so MCP
clients get the machine-readable classification the CLI's text already
implies.

The existing domain enums are not replaced — they remain the internal
throwing vocabulary (`BuildSystemError`, `SetupBuilderError`,
`IOSPreviewSessionError` and the resolver's ownership errors), and a
single boundary adapter beside the formatter maps a thrown domain error
to a `PhaseFailure`, deriving `message` from the enum's
`errorDescription`. That derivation is what keeps the pinned guard tokens
correct by construction — T02's `"Setup package '<X>' build failed"`
(`SetupBuilder.swift:298-299`) flows through unchanged rather than being
hand-copied into a new call site where it could drift. The same adapter
retires the last string-typed classification carrier:
`PreviewSessionHandle.terminalFailure` (`PreviewSessionHandle.swift:63`,
formatted today by `terminalFailureResult`,
`MCPServerSupport.swift:153-156`) becomes `PhaseFailure`-typed with
`code: .sessionFailed`, so session-death classification travels the same
path as every other failure instead of as a parallel hand-formatted
string. Existing hand-built `isError` sites migrate to the adapter where
a row needs them (the start path's build/setup catches); a whole-tree
sweep is deliberately not required — the flattener at
`PreviewsMCPServer.swift:158` stays as the backstop for un-migrated
throws, and protocol-level `MCPError`s pass through untouched.

Alternative rejected: a per-request phase tracker threaded through
dispatch so that *any* escaped error gets phase attribution. Every row in
this family is retired by a specific classification at a known catch
site; the generic net would exist for failures no reproduced row
produces, at the cost of a reference type threaded through the
deliberately immutable shared `HandlerContext`
(`HandlerContext.swift:14-22`). Deferred until an opacity report
reproduces on a path no classified site covers.

Alternative rejected: extending the JSON-RPC error object with structured
data. Tool-level failures belong in tool results per MCP convention
(`isError`), and the CLI already consumes result text; protocol errors stay
protocol-level.

### The notices carrier

A notice is a disclosure that rides a *successful* response: the crash
incident (today's `appendingIncidentNotice`), a setup that failed but
rendered without setup, an ownership loss on a live session. One shape:

```swift
public struct Notice: Sendable {
    public let code: NoticeCode   // agentCrashed, setupFailed, setupIgnored, ownershipLost
    public let message: String
}
```

Carrier rules, now normative for all notices (generalizing the two
constraints stage 2 of state-invalidation established for the crash
notice):

- A notice is appended as a **trailing** `.text` content item; `content[0]`
  is never displaced or amended. Where the response already builds
  `structuredContent`, the same notices are mirrored into a
  `"notices": [{code, message}]` array; a notice never rides *only* a
  structure that may be nil.
- A pending notice is cleared only when a response actually **carried** it
  (`appendingIncidentNotice` stays the single attach point and becomes
  notice-typed). Re-arm on each new occurrence.
- The crash notice's existing sentence is kept verbatim — L04's guard pins
  its tokens; the notice code rides `structuredContent` only.
- One uniform CLI rule, not a per-command patch: trailing notice text is
  a diagnostic and goes to **stderr** for every command; stdout carries
  only the payload. This retires both halves of the `elements` hazard in
  the evidence section (the `--json` path shows notices at all via the
  `structuredContent.notices` mirror; the default path stops
  concatenating them onto the machine payload) and means the next
  command to grow a machine-readable stdout inherits the rule instead of
  re-hitting the corruption.
- `PreviewStartResult.setupWarning` stays for wire compatibility and is
  populated from the same notice that rides the content items.

### The phase clock: elapsed-time heartbeats (L03, P01, T03)

`ProgressReporter` gains one new requirement and one derived entry point;
the boundary `report` stays for call sites with nothing to wrap:

```swift
public protocol ProgressReporter: Sendable {
    func report(_ phase: BuildPhase, message: String) async
    /// Read-only re-emit of the current step with an elapsed marker.
    /// Must not advance any step counter.
    func tick(message: String, elapsed: Duration) async
}

extension ProgressReporter {
    func phase<T>(_ phase: BuildPhase, _ message: String,
                  work: () async throws -> T) async rethrows -> T
}
```

The split matters: the tick's emission needs the concrete reporter's
channels (`MCPProgressReporter`'s private `server`, `progressToken`, and
`stepCounter`, `MCPServerSupport.swift:10-21`), which a protocol
extension cannot reach — and routing ticks through `report` instead
would increment the step counter per tick and walk the `[step/total]`
numbering forward during one phase. So `tick` is a requirement each
conformer implements against its own channels, and `phase(_:_:work:)` is
the shared default composing them.

`phase(_:_:work:)` reports the boundary line exactly as today, then starts
a ticker: after 5 seconds, and every 5 seconds thereafter, it ticks the
same step with the elapsed time — `[2/3] Building (SPMBuildSystem)... (10s)`
— through the same two channels (`logger:"preview"` log always, which the
CLI already forwards to stderr; `ProgressNotification` when the caller
supplied a token, with a fractional progress bump capped below the next
step so values stay monotonic — MCP progress must increase). `[step/total]`
numbering is unchanged by construction. The ticker is cancelled when the
work returns or throws; the throw itself propagates untouched — failure
classification is the catch sites' job, not the clock's. The tick message
carries elapsed seconds only — parsing build-tool output for finer
progress is rejected below.

Two executor rules are normative, or L03 ticks zero times. First, the
ticker runs on its own executor (`Task.detached` or equivalent), never
isolated to the caller. Second, the phase wrapper sits at the *caller*
layer — `HostApp.jitRender` (`HostApp.swift:350-354`) and the iOS render
call sites — never inside the reloaders: both are actors
(`JITStructuralReloader.swift:17`, `IOSJITStructuralReloader.swift:12`),
and the render entry is a synchronous FFI call
(`runOnMain` → `callSPSWrapper`, `PreviewsJITLinkCxx.cpp:522-529`) that
pins its executor thread until the agent returns — an actor-isolated
ticker behind that call would never fire. The blocking call itself moves
off the cooperative pool via the existing `offCooperativePool` pattern
(`PreviewSession.swift:76`, hoisted from private for sharing), which also
removes the residual bound where N concurrent sessions' renders (L05's
shape) could pin N cooperative threads and starve woken tickers. P01's
build phase has no such hazard — the subprocess runner suspends cleanly
(`AsyncProcess`). Implementation note (stage 2): moving the blocking
entries behind `await` makes every suspension an actor-reentrancy
window, so the two reloaders re-serialize the non-Sendable `JITSession`
by different, deliberate means — macOS's `JITStructuralReloader` chains
its public operations internally (no session-level lock exists there),
while iOS relies on `IOSPreviewSession`'s render lock, which every
render caller already holds. Don't assume symmetry when editing either.

`BuildPhase` gains the two phases that exist but are invisible today:
`.runningSetup` and `.rendering`; the macOS start's `totalSteps` grows
accordingly (step totals are informational; no guard pins them).

Call sites wrapped: the native build + capture (`detectBuildContext`,
covering P01's 11.8-second silent build), the Tier 2 / bridge compile, the
JIT link + render entry (covering L03's 8-second render), the setup run
(T03), and the iOS boot/install/launch/connect awaits. The reporter is
threaded (optionally) through `compileObjectForJIT` and the render call
path on both platforms; watcher-triggered refreshes have no request to
tick to and pass no reporter — a nil reporter starts **no ticker** (no
`Task.detached` spawned and cancelled per debounced save on the
hot-reload path); those phases keep logging boundary lines in
`serve.log` only.

`AsyncProcess` is untouched: it still returns child output at exit
(`AsyncProcess.swift:303-326`), and builds still run without timeouts
(`:120-123` stays authoritative). The heartbeat is external to the phase's
work by design — it observes the clock, not the child.

Cadence: 5 seconds. The matrix's silent intervals (8s, 8s, 11.8s) yield one
to two ticks; sub-5-second phases — every healthy fixture start — emit
nothing new.

### Setup integrity (T01, T03)

Three changes, all at the seam the empirical pass isolated:

1. **Wire setup independently of the Tier 2 split.** `hasSetup` becomes
   `isUsableSetup(module:type:) && setupDylibPath != nil &&
   buildContext != nil` (`PreviewSession.swift:209-211`) — the dropped
   `splitContext` guard implicitly carried the build-context invariant,
   and `setupDylibPath` alone cannot re-establish it (`buildSetupIfConfigured`
   builds the dylib independent of any build context), so standalone mode
   must stay excluded explicitly or the no-bulk branch would compile
   setup-wrapped source with no target context at all; the no-bulk
   compile branch gains
   `setupCompilerFlags` and `overrideSDK: setupSDKPath` exactly as both
   split branches already pass them (`PreviewSession.swift:277-279,291-292`
   vs `:305-309`). The decoupling leans on `setupCompilerFlags` carrying
   the search path that resolves the bridge's `import <setupModule>`
   (`BridgeGenerator.swift:74`) — the same dependency both split branches
   already rely on. A configured setup that still cannot be wired
   (standalone mode — no build context) keeps today's warning, now as a
   `setupIgnored` notice.
2. **Propagate the throw across the process boundary.** The generated entry
   becomes status-returning — `@_cdecl("previewSetUp") -> Int32` — catching
   the error instead of `try?`-dropping it (`BridgeGenerator.swift:509-522`),
   writing `String(describing: error)` to a setup-error sidecar path baked
   into the bridge (the frame-sidecar precedent,
   `PreviewSession.frameSidecarPath`), recording the failure, and
   returning nonzero. The failure record must live for the **agent
   process's** lifetime, not the bridge module's: setup runs once per
   agent (`!didRunSetUp`, `JITStructuralReloader.swift:49`) while every
   generation links a fresh bridge module whose statics reset — a
   bridge-module flag would silently re-enable `wrap` on the first
   post-failure edit. So the flag lives in `PreviewsSetupKit` (a
   `nonisolated(unsafe)` static in the kit the setup dylib links exactly
   once per agent, the same process-lifetime reasoning that shares
   `libPreviewSetup.dylib` statics, `SetupBuilder.swift:118-264`): the
   generated entry sets it, and every generation's `viewWithSetup`
   consults it and skips `wrap` while it stands — the documented contract
   is "renders without setup" (`docs/setup-plugin.md:12`), and wrapping
   through a plugin whose `setUp()` failed would hand it half-initialized
   state, on the first render or any later generation. The reloader
   reads the status it currently discards (`JITStructuralReloader.swift:49-52,65-67`,
   `IOSJITStructuralReloader.swift:50-53`); on nonzero the session reads
   the sidecar and arms a `setupFailed` notice — take-and-clear, same as
   the crash notice — that the start response (and any later response, if
   the failure happened on a respawned agent's re-run) carries: `"Preview
   setup '<TypeName>' failed: <error>. The preview rendered without
   setup."` A failed setup still counts as this agent's run — no retry
   loop; an agent respawn re-runs setup naturally (`didRunSetUp` resets
   with the agent, `JITStructuralReloader.swift:72`).
   The status change is ABI-safe with no agent rebuild: the agent already
   invokes run-on-main symbols as `int32_t (*)()`
   (`PreviewAgent/main.cpp:99-114`), today's `void` entry just yields a
   garbage word both reloaders discard (`JITStructuralReloader.swift:50`,
   `IOSJITStructuralReloader.swift:51`), and the entry is JIT-compiled,
   not baked into the agent binary. The sidecar write is proven for macOS
   (the agent is a plain host process; the frame sidecar is the precedent,
   `BridgeGenerator.swift:261-279` — a macOS-only mechanism today). iOS
   has no in-tree precedent for the agent writing a daemon-chosen host
   path; simulator apps are host processes sharing the filesystem, so the
   same sidecar is expected to work, and stage 3's manual pass explicitly
   verifies the sim-app → host-path → daemon round-trip on the T01
   fixture before anything is built on it. If the write proves
   restricted, the named fallback is the agent → daemon JSON channel that
   already carries `latestJITError` (`IOSAgentChannel.swift:379-381`).
3. **Make the setup run a phase.** The setup entry falls under the same
   normative placement rule as the render entry (the phase-clock section
   above): the `.runningSetup` wrapper sits at the caller layer with a
   detached ticker, never inside the reloader actor — the setup entry is
   the same thread-pinning synchronous EPC shape as the render entry. So
   T03's 8-second setup ticks `Running preview setup... (5s)` instead of
   holding the start in silence.

T03's ordering contract — "finish setup before the first render" — already
holds once setup is wired: verified 2026-07-16, the wired variant blocked
the start for the full sleep and rendered the completed overlay. The design
records it as an invariant (setup entry precedes the render entry on every
fresh agent, `JITStructuralReloader.swift:65-68`) rather than new
machinery, and VERIFICATION.md gets a regression note correcting the row's
recorded mechanism, as W02's did.

### JIT symbol disclosure (R01, L02)

The engine captures what it already knows and stops splitting it from the
returned error:

- One reporter install covers both platforms: after
  `createRemoteSessionFromFDs` builds the LLJIT
  (`PreviewsJITLinkCxx.cpp:360-450`), it installs an ExecutionSession
  error reporter that appends each reported error string to a
  mutex-guarded per-session buffer — and still logs it, the log keeps its
  copy. The buffer is scoped to one materialization attempt: cleared at
  each lookup/run entry, so a failure on the fiftieth re-render drains
  only that attempt's reports, never strings accumulated across a
  session's lifetime of successful renders. Materialization runs in the daemon process on both platforms (the
  evidence section above), so no cross-process shipping is needed; the
  sim-side executor's `logAllUnhandledErrors` sinks are EPC-transport
  lifecycle reporting and stay untouched. When `lookupInitialized` or a
  run entry fails (`PreviewsJITLinkCxx.cpp:306-322,494-531`), the returned
  string becomes the flattened error plus the drained buffer — the
  `Symbols not found: [ ... ]` list now travels with the failure instead
  of beside it. That ORC routes the symbol dump through the session's
  reporter is expected but unexecuted — stage 4 opens with a spike proving
  the capture against the L02 fixture before the classification is built
  on it.
- Swift-side classification parses the symbol list out of the combined
  string into `PhaseFailure(phase: .rendering, code: .unresolvedSymbols)`:
  message names the count and the first few mangled symbols (bounded),
  detail carries the full bounded list, remediation states the known cause
  shape — the target may rely on autolinked frameworks the preview JIT
  does not load (`dependencyDylibs` resolves only explicit `-F`/`-framework`
  pairs, `PreviewSession.swift:367-393`). L02's injected symbol is named to
  the caller; R01's autolink-closure dump becomes a classified session
  error, which is the row's contract ("render **or** return a classified
  session error").

Named limitations: this classifies the autolink gap, it does not close it
— actually rendering R01 means resolving the target-wide autolink closure
(scan captured objects' `LC_LINKER_OPTION` load commands into `addDylib`
calls), recorded as the natural follow-up with this classification as its
stepping stone. And the iOS in-app executor's coarse
`jitExecutorFailed(stage:code:)` lifecycle surface (#217,
`IOSPreviewSession.swift:611-618`) is a different failure family —
executor startup and transport, not materialization — and is not reworked
here.

### Native-build failure enrichment (F01)

`buildFailed` grows a classifier pass before formatting: when the stderr
matches `no such module '<M>'` and `<M>` is a declared `binaryTarget`,
the enricher acts. The gate must be answerable without new work: the
resolver design intended describe output to ride along on `Ownership`
but that carrier never shipped (`OwnershipResolver.swift:4-24` carries
only kind/root/target/projectFile; `BuildContext` has no manifest model,
`BuildContext.swift:4-57`), so stage 4 retains the binary-target
name → declared-path pairs on `BuildContext`, captured where the SPM
confirm step already decodes the manifest — fulfilling the resolver's
ride-along intent for exactly the fields this needs. Classification then
reads a field; no `describe` runs at failure time, which also keeps the
enricher free on the much larger class of `no such module` failures
(typos, unresolved dependencies) that are not binary targets at all. It
locates the artifact at
the target's declared `path:` (the F01 fixture declares
`Artifacts/BadSlice.xcframework`; the path is read from the declaration,
never assumed beside the manifest) or under `.build/artifacts/` for
fetched binary targets, reads `<name>.xcframework/Info.plist`, and checks
`AvailableLibraries` for a slice matching the requested platform and
variant (iOS previews require `SupportedPlatform == "ios"` with
`SupportedPlatformVariant == "simulator"`; macOS previews `"macos"`, no
variant). No match yields
`PhaseFailure(phase: .buildingProject, code: .incompatibleSlice)`: the
message names the module, the available `LibraryIdentifier`s, and the slice
the preview needed; the remediation says to rebuild the XCFramework with a
simulator slice. Any miss in the chain — no manifest, no artifact, plist
unreadable, a slice actually present (the failure was something else) —
degrades to today's `buildFailed` text through the boundary adapter's
`.buildFailed` classification; the enricher
can only ever add information. Architecture checking is deliberately out
(platform + variant retires F01; Rosetta nuances have no row). Xcode and
Bazel binary dependencies keep the unenriched error — named limitation, no
reproduced row (F01 is SwiftPM).

### Ownership loss on a live session

The refresh executors' keep-preview behavior is deliberate
(`docs/state-invalidation.md` licenses it), but the event now has a
carrier: when re-resolve finds no owner
(`HostApp.swift:219-225`, `IOSPreviewSession.swift:738-743`), the session
arms an `ownershipLost` notice — "no build system resolves `<file>` any
more; the preview continues on its last successful build" — delivered on
the session's next response through the notices carrier, cleared on
delivery, re-armed per occurrence. The log line stays; it is now the copy,
not the record.

## Implementation stages, each ending in a manual matrix pass

Stages follow the family discipline: design → adversarial review → gates
(/simplify, /code-review, unit tier, integration tier) → manual matrix
re-verification flipping rows in VERIFICATION.md before the next stage.

1. **Protocol carrier.** `PhaseFailure`/`FailureCode`/`Notice` in
   `PreviewsCore`; the one-place formatter and the domain-enum boundary
   adapter (including `terminalFailure` becoming `PhaseFailure`-typed);
   the notices carrier subsuming the crash disclosure (text verbatim —
   L04 tokens hold) and mirroring `setupWarning`; the
   `structuredContent.notices` mirror plus the uniform CLI
   notices-to-stderr rule. Flips nothing — the enabler stage, like
   EvidenceSet capture was. Manual: every pinned guard token holds
   (T02, D06, D07, V05, M02), and L04's disclosure re-verified through
   the typed carrier on both `elements` CLI paths — `--json` now shows it
   at all (today it is cleared without being shown), and the default path
   shows it on stderr with the stdout JSON no longer corrupted.
2. **Phase clock.** `phase(_:_:work:)` with the 5-second ticker; reporter
   threaded through the compile/render path; `.runningSetup`/`.rendering`
   phases. Manual: **L03 and P01 flip** (ticks observed in the CLI's
   stderr with timestamps); fast rows stay tick-free.
3. **Setup integrity.** Decouple `hasSetup` from the split; status-word
   setup entry + error sidecar + `wrap` skip; `setupFailed`/`setupIgnored`
   notices; setup phase ticks. Manual: **T01 and T03 flip** (T01: throwing
   setup renders with the failure notice on the start response; T03: wired
   setup blocks, ticks, completes before first render), T02 holds, W-row
   and L-row guards hold, plus a VERIFICATION.md regression note on T03's
   original mechanism.
4. **Failure classification.** Opens with the reporter spike: install the
   ExecutionSession error reporter in `createRemoteSessionFromFDs` and
   prove `Symbols not found` is captured against the L02 fixture. Then
   the attempt-scoped combined error strings, the `unresolvedSymbols`
   classification, the binary-target name → path retention on
   `BuildContext`, and the F01 slice enricher. Manual: **F01, R01, L02
   flip**; B02/B03/B04 and the resolver guards hold.

Stage 1 is the base for 3 and 4; stage 3 additionally needs stage 2 (its
setup tick runs under `phase(_:_:work:)` and `.runningSetup`, which stage
2 introduces). Stage 4 is independent of 2 and 3. Recommended order as
numbered — the clock is the smallest lever and de-risks the two
pure-heartbeat rows early.

## Out of scope

- Loading the autolink framework closure so R01 *renders* (the
  `LC_LINKER_OPTION` scan): future work; this family delivers the
  classified error the row accepts and the diagnosis that work needs.
- Streaming or parsing build-tool child output for finer-grained progress;
  the contract is elapsed-time heartbeats, and `AsyncProcess`'s
  capture-at-exit shape stays.
- CLI-originated `progressToken`s: the log-notification channel already
  reaches the CLI's stderr; tokens remain for MCP clients that opt in.
- Retry or self-healing on classified failures; classification changes
  what the caller knows, not what the daemon attempts.
- The resource-staging cluster (B04, R02, R03) — needs its own family
  home; and semantic interaction (I01–I03).

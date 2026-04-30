# preview_record — Implementation Plan

**Spec:** [`SPEC.md`](../SPEC.md)
**Date:** 2026-04-19 (updated for daemon architecture, rebased on main)
**Branch:** `worktree-preview-record-spec`

## Architecture context (post-rebase)

Since the original plan was written, the project adopted a daemon-based architecture (#113). Key impacts:

- **CLI/MCP parity:** every MCP tool has a corresponding CLI subcommand that connects to the daemon via `DaemonClient.withDaemonClient` over a Unix domain socket. New recording tools need CLI commands too.
- **Tool schemas extracted to `MCPToolSchemas.swift`** — `ToolName` enum and schema definitions live there, not inline in `MCPServer.swift`.
- **Structured content:** tool handlers emit `DaemonProtocol` DTOs via `structuredContent` alongside text content blocks. New tools need DTOs.
- **Session resolution:** CLI commands use `SessionResolver` + `SessionTargetingOptions` for `--session`/`--file` targeting. Recording commands reuse this.
- **Test serialization:** daemon-touching tests use `DaemonTestLock` (flock) for cross-suite ordering. New integration tests must acquire this lock.
- **Command registration:** new subcommands register in `PreviewsMCPApp.swift`.
- **Output conventions:** read-oriented commands get `--json`; imperative commands write confirmations to stderr only.

The dispatch switch in `MCPServer.swift:100-128` is structurally unchanged — middleware still plugs in there.

## Approach

Vertical slicing. Each slice ends with a shippable, testable end-to-end path — not a horizontal layer.

Six slices, with human review checkpoints at the end of slices 1, 2, and 4.

## Dependency graph

```
                ┌─────────────────────────────────────────┐
                │  Slice 1: Core primitives               │
                │  FrameDiff · KeyframeSelector · ActionLog │
                │  (pure Swift, unit-tested in isolation) │
                └─────────────────────────────────────────┘
                       │                          │
                       ▼                          ▼
  ┌────────────────────────────────┐   (ActionLog unused until Slice 4)
  │ Slice 2: macOS preview_record  │
  │ SnapshotRecorder · TouchOverlay   │
  │ + RecordCommand CLI            │
  │ + DaemonProtocol.RecordResult  │
  │ (atomic keyframe capture,      │
  │  end-to-end on macOS)          │
  └────────────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────┐
  │ Slice 3: iOS preview_record    │
  │ SimctlRecorder · AVAssetReader │
  │ (iOS parity — reuses diff,     │
  │  selector, overlay from S1/S2) │
  └────────────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────────────────────────────┐
  │ Slice 4: macOS session recording                       │
  │ RecordingState · Dispatcher middleware                 │
  │ preview_record_start/stop handlers                     │
  │ RecordStartCommand + RecordStopCommand CLI              │
  │ DaemonProtocol.RecordStartResult/RecordStopResult DTOs │
  │ AVVideoCompositionCoreAnimationTool overlay             │
  │ Implicit finalize on preview_stop                      │
  └────────────────────────────────────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────┐
  │ Slice 5: iOS session recording │
  │ (reuses S4 middleware + state, │
  │  adds iOS recorder to handlers)│
  └────────────────────────────────┘
                       │
                       ▼
  ┌────────────────────────────────┐
  │ Slice 6: Polish                │
  │ Spritesheet format             │
  │ no-motion branch               │
  │ frame index overlay on sheet   │
  └────────────────────────────────┘
```

## Slices

### Slice 1 — Core primitives

**Goal:** Ship pure Swift algorithms for frame diff, keyframe selection, and action log. Zero platform dependencies. Fully unit-testable.

**Why first:** Everything downstream depends on these. They have no I/O and no platform surface, so we can iterate on algorithm correctness without ever touching a simulator or a window.

**Changes:**
- `Sources/PreviewsCore/Recording/FrameDiff.swift`
  - `struct FrameDiff { static func ssim(_ a: CGImage, _ b: CGImage) -> Double }`
  - Grayscale conversion to 128×128, 8×8 window SSIM per Wang et al. (reference, do not reinvent).
  - Inputs as `CGImage` — the common frame type across macOS (`NSBitmapImageRep.cgImage`) and iOS (`AVAssetReader` → `CVPixelBuffer` → `CGImage`). CoreGraphics only, no AppKit dependency.
- `Sources/PreviewsCore/Recording/KeyframeSelector.swift`
  - `struct KeyframeSelector { static func select(diffs: [Double], frameCount: Int, minGapMs: Int, fps: Int, motionThreshold: Double, stillThreshold: Double) -> KeyframeSelection }`
  - Returns `(motionStartFrame, motionEndFrame, selectedIndices)`. Pairwise threshold-gated scene detect + min-gap + forced endpoints. No cumulative-diff.
- `Sources/PreviewsCore/Recording/ActionLog.swift`
  - `public struct ActionLogEntry: Sendable, Codable { let tMs: Int; let tool: String; let params: [String: AnyCodable]; let causedRecompile: Bool }`
  - `public actor ActionLog { append(...); entries() -> [ActionLogEntry] }`
  - Sendable for cross-isolation use. Serialization round-trip tested.
  - For `AnyCodable`, use `MCP.Value` from the swift-sdk (already a dependency) rather than a custom wrapper or new dependency.
- `Tests/PreviewsCoreTests/FrameDiffTests.swift`
  - Identical frames → SSIM = 1.0 (±1e-6)
  - Inverted frames → SSIM near 0
  - Known gradient shifts → SSIM in expected bounds
- `Tests/PreviewsCoreTests/KeyframeSelectorTests.swift`
  - Synthetic diff arrays: all-zero (no motion), all-high (continuous motion), single spike, ease-out decay
  - Min-gap respected (no two frames closer than `minGapMs`)
  - First/last frame of motion window always included
  - `frameCount` budget: fewer candidates than budget → fill with next-highest; more candidates → prefer highest diff
- `Tests/PreviewsCoreTests/ActionLogTests.swift`
  - Ordering preserved on concurrent appends
  - Monotonic timestamps (no reordering on serialize)
  - JSON round-trip equality

**Acceptance criteria:**
- `swift test --filter FrameDiff` passes
- `swift test --filter KeyframeSelector` passes
- `swift test --filter ActionLog` passes
- No new warnings under strict concurrency
- `swift build` still succeeds for all existing targets

**Verification:**
```bash
swift test --filter "FrameDiff|KeyframeSelector|ActionLog"
swift build
```

**→ CHECKPOINT 1: Human review.** Algorithm correctness is frozen here. Next slices layer I/O on top.

---

### Slice 2 — macOS `preview_record` (end-to-end, atomic)

**Goal:** A working `preview_record` MCP tool + `record` CLI subcommand on macOS. Tap an animated button, get 6 keyframes with touch overlays back inline. No session recording yet.

**Why second:** Proves the full pipeline (capture → diff → select → overlay → encode → return) on the cheaper platform before paying iOS decode cost. Most likely place for surprises (timer-polled `Snapshot.capture` edge cases, window targeting, encoding latency) — surface them now.

**Changes:**
- `Sources/PreviewsMacOS/Recording/SnapshotRecorder.swift`
  - `@MainActor class SnapshotRecorder { init(window: NSWindow); func start(fps: Int); func stop() -> [(CGImage, ContinuousClock.Instant)] }`
  - Timer-polled `Snapshot.capture` at ~30fps (reuses existing `bitmapImageRepForCachingDisplay` + `cacheDisplay` code path).
  - Use `DispatchSource.makeTimerSource(queue: .main)` (not `Timer.scheduledTimer`) to avoid run-loop-mode coalescing during tracking events that could bunch frames.
  - In-memory frame buffer of `(CGImage, ContinuousClock.Instant)` tuples. No new frameworks, no TCC permissions, works headless.
- `Sources/PreviewsCore/Recording/TouchOverlay.swift`
  - `struct TouchOverlay { static func composite(onto: CGImage, taps: [TouchEvent], atFrameTime: Int) -> CGImage }`
  - CoreGraphics `CGContext` draw (single-frame use — used for keyframe output in slices 2 & 3).
  - Fading circle, alpha 1.0 → 0 over 500ms relative to tap time.
- `Sources/PreviewsCLI/MCPToolSchemas.swift`
  - Add `ToolName.previewRecord = "preview_record"` to the enum.
  - Add tool schema to `mcpToolSchemas()` return array.
- `Sources/PreviewsCLI/MCPServer.swift`
  - Add `case .previewRecord` to the dispatch switch.
  - `handlePreviewRecord(params:)` for macOS: target window from `App.host.window(for: sessionID)`, instantiate `SnapshotRecorder`, start capture, fire trigger via existing touch code path, record tap event into a local `[TouchEvent]`, stop capture, run `FrameDiff` on adjacent pairs, run `KeyframeSelector`, composite overlays via `TouchOverlay`, JPEG-encode, return inline `.image(...)` content matching `preview_snapshot` convention.
  - iOS path returns `isError: true` with "iOS preview_record not yet supported" message.
  - Emit `structuredContent` via `DaemonProtocol.RecordResult` DTO alongside images.
- `Sources/PreviewsCLI/DaemonProtocol.swift`
  - Add `RecordResult` DTO: `{ durationMs: Int, motionStartMs: Int, motionEndMs: Int, framesReturned: Int, warning: String? }`.
- `Sources/PreviewsCLI/RecordCommand.swift` **(new file)**
  - CLI subcommand: `previewsmcp record <x> <y> [--session|--file] [--output <dir>] [--frame-count 6] [--max-duration 3000] [--format sequence|spritesheet] [--quality 0.85] [--json]`
  - Daemon client pattern: `DaemonClient.withDaemonClient` → `SessionResolver.resolve` → `client.callToolStructured("preview_record", ...)`.
  - Read-oriented → supports `--json` (emits `RecordResult` + frame file paths to stdout).
  - Writes frames to disk at `--output` directory (CLI-specific; the MCP tool returns inline).
  - Uses `@OptionGroup var target: SessionTargetingOptions`.
- `Sources/PreviewsCLI/PreviewsMCPApp.swift`
  - Register `RecordCommand` as a subcommand.
- `Tests/MCPIntegrationTests/PreviewRecordMacOSTests.swift`
  - New fixture: `TestPreviews/AnimatedButton.swift` — button that, on tap, animates `scaleEffect(pressed ? 0.8 : 1.0)` with a 0.5s ease-out.
  - Start a macOS preview session, call `preview_record` with tap on the button, assert:
    - Response content has ≥2 and ≤12 images
    - `structuredContent` decodes to `RecordResult` with `durationMs` in expected range
    - No `warning` field
  - No-motion test: tap on a blank region, assert single frame + `warning` present.
  - Uses `DaemonTestLock` for cross-suite serialization.

**Acceptance criteria:**
- `swift test --filter PreviewRecordMacOS` passes
- `preview_record` tool appears in `ListTools` output
- `previewsmcp record` CLI subcommand works against the daemon
- iOS call returns a clear "not yet supported" error, not a crash
- `previewsmcp record --json` emits valid JSON to stdout

**Verification:**
```bash
swift test --filter "PreviewRecordMacOS"
swift build && .build/debug/previewsmcp record --help
```

**Risks:**
- `bitmapImageRepForCachingDisplay` is `@MainActor`. The capture timer callback must dispatch to the main actor, which means frame capture competes with SwiftUI layout/render. At 30fps for a 400×600 window this is <1ms per frame — negligible. But very complex layouts may cause occasional frame drops. Mitigation: allow dropped frames in the diff buffer (the algorithm tolerates gaps).
- Touch overlay timing: the tap event fires between frames. Pick "nearest frame by wall-clock" for overlay anchoring, not interpolation.

**→ CHECKPOINT 2: Human review.** End-to-end UX is testable. Decide if keyframe quality, overlay appearance, and return format are right before replicating the pattern on iOS.

---

### Slice 3 — iOS `preview_record`

**Goal:** iOS parity for `preview_record`. Reuses everything from Slices 1 & 2 except the capture path and an AVAssetReader decode step. CLI command already works (daemon routes to the iOS handler; `RecordCommand` doesn't need changes).

**Why third:** iOS capture is the expensive path (simctl serializes to a .mov file, which must be decoded frame-by-frame to get `CVPixelBuffer`s for SSIM). Isolating it here means we're only debugging one new thing — the decode pipeline — not also the algorithm or the overlay.

**Changes:**
- `Sources/PreviewsIOS/Recording/SimctlRecorder.swift`
  - `actor SimctlRecorder { init(deviceUDID: String); func start(codec: String); func stop() -> URL }`
  - Forks `xcrun simctl io <udid> recordVideo --codec <codec> <temp path>`, tracks `Process`, terminates with SIGINT (not SIGTERM — simctl requires SIGINT to close the container).
  - Returns the .mov file path on stop.
- `Sources/PreviewsCore/Recording/MovieDecoder.swift`
  - `struct MovieDecoder { static func decodeFrames(at: URL) async throws -> [CGImage] }`
  - `AVAssetReader` + `AVAssetReaderTrackOutput` with `kCVPixelFormatType_32BGRA` output. Converts each `CVPixelBuffer` → `CGImage` internally (via `CGContext`-backed render from the buffer's base address). Returns `[CGImage]` so downstream code (FrameDiff, KeyframeSelector, TouchOverlay) consumes the common type directly — no conversion step needed at the call site.
- `Sources/PreviewsCLI/MCPServer.swift`
  - Fill in the iOS branch of `handlePreviewRecord`:
    - Get iOS session → `SimctlRecorder`
    - Start → fire trigger via existing iOS touch path (recording tap event locally) → stop
    - `MovieDecoder.decodeFrames(at:)` → pixel buffer array
    - Same FrameDiff → KeyframeSelector → TouchOverlay → JPEG → inline image pipeline as macOS
- `Tests/MCPIntegrationTests/PreviewRecordIOSTests.swift`
  - Mirror of `PreviewRecordMacOSTests` on the iOS path. Slow — boots a real sim.
  - Minimum: one happy-path test (tap animated button, get keyframes) + one no-motion test.
  - Uses `DaemonTestLock`.

**Acceptance criteria:**
- `swift test --filter "PreviewRecordIOS"` passes (slow, ~30s)
- `previewsmcp record` CLI works against an iOS session
- No regression in existing iOS tests (`swift test --filter "IOSPreviewSession"`)

**Verification:**
```bash
swift test --filter "PreviewRecordIOS|IOSPreviewSession"
```

**Risks:**
- `simctl` finalization race: sending SIGINT too early truncates the container. Mitigation: sleep 100ms after stopping capture before SIGINT, verify file is non-zero after `waitpid`.
- AVAssetReader pixel format: iOS simulator may emit `kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange`. Force BGRA via `AVAssetReaderTrackOutput` settings.

---

### Slice 4 — macOS session recording (`preview_record_start` / `preview_record_stop`)

**Goal:** Session-scoped video recording on macOS. Shipping `preview_record_start`, `preview_record_stop` MCP tools + CLI commands, the dispatcher middleware, the action log integration, AVFoundation overlay compositing at stop time, and implicit finalize on `preview_stop`.

**Why fourth:** This is the biggest slice and the most architecturally invasive (it touches the dispatch layer, adds new global state, and introduces AVFoundation composition). It must land after the atomic `preview_record` slices because it reuses `SnapshotRecorder` and `ActionLog`.

**Changes:**
- `Sources/PreviewsCLI/RecordingState.swift`
  - `actor RecordingState { struct ActiveRecording { let recorder: any Recorder; let actionLog: ActionLog; let startedAt: ContinuousClock.Instant } }`
  - Keyed by `sessionID`. Methods: `start(sessionID:recorder:)`, `isActive(sessionID:)`, `log(sessionID:tool:params:)`, `stop(sessionID:) -> (URL, [ActionLogEntry])`.
- `Sources/PreviewsCore/Recording/Recorder.swift`
  - `protocol Recorder: Sendable { func start() async throws; func stop() async throws -> URL }`
  - Abstraction over SnapshotRecorder (macOS) and SimctlRecorder (iOS, slice 5). macOS session variant uses `AVAssetWriter` + `AVAssetWriterInputPixelBufferAdaptor` to encode each timer-polled `Snapshot.capture` frame into a `.mov` live.
- `Sources/PreviewsMacOS/Recording/PixelBufferConverter.swift`
  - `struct PixelBufferConverter { static func convert(_ image: CGImage, pool: CVPixelBufferPool) -> CVPixelBuffer }`
  - Creates a `CGContext` backed by the `CVPixelBuffer`'s base address, draws the `CGImage` into it. Used by `SnapshotRecorder`'s session mode to feed `AVAssetWriterInputPixelBufferAdaptor`. The pixel buffer pool is created once per recording session from the `AVAssetWriter`.
- `Sources/PreviewsCore/Recording/SessionOverlay.swift`
  - `struct SessionOverlay { static func composite(rawVideo: URL, actions: [ActionLogEntry], output: URL) async throws }`
  - Builds a CALayer tree with fading-circle overlays per tap/swipe event, uses `AVVideoCompositionCoreAnimationTool`, exports via `AVAssetExportSession`.
- `Sources/PreviewsCLI/MCPToolSchemas.swift`
  - Add `ToolName.previewRecordStart` and `ToolName.previewRecordStop` to enum.
  - Add tool schemas to `mcpToolSchemas()`.
- `Sources/PreviewsCLI/MCPServer.swift`
  - Add `case .previewRecordStart, .previewRecordStop` to dispatch switch.
  - **Dispatcher middleware:** wrap the existing switch body into a helper; after the handler returns, check `recordingState.isActive(sessionID:)` and log to the action timeline if active. One touch point at the dispatch layer — not per-handler.
  - Static set: `recompileCausingTools: Set<String> = ["preview_configure", "preview_switch", "preview_variants"]`.
  - `handlePreviewRecordStart(params:)` — create session recorder for the macOS window, start, register in `RecordingState`, return `{recordingID}`. Error if already active. Emit `structuredContent` via `RecordStartResult` DTO.
  - `handlePreviewRecordStop(params:)` — `recordingState.stop(sessionID:)`, overlay composition pass, write to `NSTemporaryDirectory()/previewsmcp-<sessionID>-<uuid>.mov`, return `{path, durationMs, actions}`. Emit `structuredContent` via `RecordStopResult` DTO.
  - **Modify `handlePreviewStop`:** before running normal stop logic, check `recordingState.isActive(sessionID:)`; if true, finalize the recording first and merge its result into the stop response.
- `Sources/PreviewsCLI/DaemonProtocol.swift`
  - Add `RecordStartResult` DTO: `{ recordingID: String, sessionID: String }`.
  - Add `RecordStopResult` DTO: `{ path: String, durationMs: Int, actions: [ActionLogEntryDTO] }`.
  - Add `ActionLogEntryDTO`: `{ tMs: Int, tool: String, causedRecompile: Bool }`.
- `Sources/PreviewsCLI/RecordStartCommand.swift` **(new file)**
  - CLI subcommand: `previewsmcp record-start [--session|--file] [--codec h264|hevc]`
  - Imperative → stderr confirmation only (no `--json`), following `configure`/`switch`/`touch` pattern.
  - `DaemonClient.withDaemonClient` → `SessionResolver.resolve` → `client.callTool("preview_record_start", ...)`.
- `Sources/PreviewsCLI/RecordStopCommand.swift` **(new file)**
  - CLI subcommand: `previewsmcp record-stop [--session|--file]`
  - Read-oriented → supports `--json` (emits `RecordStopResult` including path and action log).
  - Prints the finalized `.mov` path to stdout.
- `Sources/PreviewsCLI/PreviewsMCPApp.swift`
  - Register `RecordStartCommand` and `RecordStopCommand`.
- `Tests/MCPIntegrationTests/PreviewRecordSessionMacOSTests.swift`
  - Start recording → 3 mixed tool calls (tap, switch, configure) → stop. Assert:
    - Action log length and `causedRecompile` flags correct
    - `.mov` exists, is decodable by `AVAssetReader`, duration is sane
  - Implicit-stop test: start recording → `preview_stop`, assert result includes recording path.
  - Uses `DaemonTestLock`.

**Acceptance criteria:**
- `swift test --filter "PreviewRecordSessionMacOS"` passes
- Middleware does not break any existing tool (run full test suite, zero regressions)
- `previewsmcp record-start` and `previewsmcp record-stop` CLI commands work
- Manual smoke test: record a demo, inspect the .mov in QuickTime

**Verification:**
```bash
swift test  # full suite — middleware is global
swift build && .build/debug/previewsmcp record-start --help && .build/debug/previewsmcp record-stop --help
```

**Risks:**
- Session `SnapshotRecorder` for live `.mov` encoding uses `AVAssetWriter` wrapping the timer-polled `Snapshot.capture` feed. This is a different mode from the atomic recorder in slice 2 (which stores `CGImage`s in memory). `SnapshotRecorder` should support both modes (atomic: in-memory buffer; session: live AVAssetWriter encoding) — the timer loop is the same, only the frame sink differs.
- `AVVideoCompositionCoreAnimationTool` gotcha: video layer must be a *child* of the container layer, and the container layer must not be in any visible view hierarchy.
- Middleware sessionID extraction: some tools don't take a `sessionID` (e.g., `preview_list`, `simulator_list`, `session_list`). Skip logging for those.

**→ CHECKPOINT 3: Human review.** Session recording contract is frozen. iOS is now a copy of a known-good pattern.

---

### Slice 5 — iOS session recording

**Goal:** iOS parity for `preview_record_start`/`preview_record_stop`. Reuses middleware, `RecordingState`, `ActionLog`, `SessionOverlay`, and CLI commands from slice 4. Adds an iOS-flavored recorder.

**Changes:**
- `Sources/PreviewsIOS/Recording/SessionSimctlRecorder.swift`
  - Conforms to `Recorder` protocol. Wraps `SimctlRecorder` from slice 3 (or extends it if the shape already fits).
  - `start()` forks simctl, `stop()` sends SIGINT and waits for file finalization, returns the raw .mov path.
- `Sources/PreviewsCLI/MCPServer.swift`
  - In `handlePreviewRecordStart`, branch on iOS session and use `SessionSimctlRecorder`.
  - Overlay composition pass is already platform-agnostic.
- `Tests/MCPIntegrationTests/PreviewRecordSessionIOSTests.swift`
  - Mirror of the macOS session test on iOS. Slow. One happy-path + one implicit-stop test minimum.
  - Uses `DaemonTestLock`.

**Acceptance criteria:**
- `swift test --filter "PreviewRecordSessionIOS"` passes
- No regression in existing iOS tests or in slice 4 macOS session tests
- `previewsmcp record-start` / `record-stop` work against an iOS session

**Verification:**
```bash
swift test --filter "PreviewRecordSession|IOSPreviewSession"
```

---

### Slice 6 — Polish

**Goal:** Close the remaining spec items. No new architecture, just wrapping up.

**Changes:**
- `Sources/PreviewsCore/Recording/Spritesheet.swift`
  - `struct Spritesheet { static func compose(frames: [CGImage], columns: Int) -> CGImage }`
  - `ceil(sqrt(N))` columns, row-major. Draw frame index in corner (small, contrasting).
- `Sources/PreviewsCLI/MCPServer.swift`
  - In `handlePreviewRecord`, branch on `format` parameter: `"sequence"` → multiple `.image(...)` entries (existing), `"spritesheet"` → single `.image(...)` with the composed grid.
- `Tests/MCPIntegrationTests/PreviewRecordSpritesheetTests.swift`
  - Call `preview_record` with `format: "spritesheet"`, assert single image in response.
- Documentation:
  - Update `README.md` tool list + CLI subcommands table to include the three new tools / commands.
  - Update `AGENTS.md` `## MCP Server` tools section, `### CLI subcommands` table, and `### Structured output` list.
  - Add a `## Recording` section to `AGENTS.md` matching the style of `## Trait Injection` and `## Multi-Preview Support`.

**Acceptance criteria:**
- `swift test` — all passing
- README and AGENTS.md updated
- Manual smoke test of spritesheet output

**Verification:**
```bash
swift test
swift-format lint --strict --recursive Sources/ Tests/
swiftlint lint --quiet Sources/ Tests/
```

## Non-task items (explicitly deferred)

- `outputDirectory` parameter on any tool — deferred to a follow-up PR that lands it on `preview_snapshot`, `preview_variants`, and `preview_record` uniformly.
- Rolling/continuous buffer — rejected per spec.
- Audio capture — rejected per spec.
- Semantic animation inspection (CAAnimation sniffing) — rejected per spec.

## Testing strategy recap

- **Unit tests** (`Tests/PreviewsCoreTests/`) — slice 1 only. Fast, no simulators, run in CI.
- **MCP integration tests — macOS** (`Tests/MCPIntegrationTests/PreviewRecord*MacOSTests.swift`) — slices 2, 4, 6. Uses daemon (requires `DaemonTestLock`).
- **MCP integration tests — iOS** (`Tests/MCPIntegrationTests/PreviewRecord*IOSTests.swift`) — slices 3, 5. Slow (simulator boot). Uses `DaemonTestLock`.
- **CLI tests** — daemon-touching; can share the macOS integration test suite or have dedicated `Tests/CLIIntegrationTests/RecordCommandTests.swift`.
- **Fixture:** `TestPreviews/AnimatedButton.swift` lives in the test support directory, shared across macOS and iOS record tests.

## Rollback

Each slice is a separate commit (or set of commits). If a slice lands and is later found broken, revert the commit range. No slice crosses a platform boundary alone, so a revert of one slice never leaves a half-built feature.

# preview_record — Spec

**Status:** Draft (2026-04-19, updated: drop ScreenCaptureKit in favor of timer-polled Snapshot.capture)
**Branch:** `worktree-preview-record-spec`
**Author:** Jason + Claude (Opus 4.6)

## Objective

Add animation capture and session video recording to PreviewsMCP, targeting two agentic-development pain points:

1. **Animation debugging.** An agent needs to verify that an interaction produces the right animated response — spring settles, transitions, state changes mid-flight. Today it can only read still frames, so anything time-dependent is invisible. The agent should be able to say "tap this, show me what happens" and get a sequence of keyframes it can reason about inline.

2. **Stakeholder demo recording.** A human working with an agent wants to hand a stakeholder an `.mov` of a feature in motion. Today they'd leave the tool, open `Simulator.app`, screen-record manually, trim in QuickTime. The agent should be able to record a scripted multi-step flow and produce a shareable video with a synced action timeline.

These are distinct enough in shape (atomic vs. session, inline frames vs. file path) that they warrant separate tools rather than one tool with a `mode` param.

## Non-goals

- **Semantic animation inspection.** Chrome DevTools' Animation panel shows easing curves and lets you scrub CAAnimations by name. We cannot match this without private API sniffing of SwiftUI's animation engine. Keyframes are a weak visual substitute; we acknowledge the gap and do not try to bolt "which spring animation fired" onto frame output.
- **Visual regression testing.** Chromatic/Percy explicitly freeze animations for determinism. This tool does the opposite — captures motion. Do not let assertion/diff workflows creep in.
- **Rolling/continuous retroactive capture.** Rejected: preview sessions are deterministic up to `@State`, and re-triggering an interaction is one tool call. Cheaper to retry than to maintain an always-on 60fps buffer with memory pressure, teardown races against hot-reload, and new state to reason about.
- **Audio.** SwiftUI previews have no audio path worth capturing.

## Tools

Three new MCP tools. All require a running session from `preview_start`.

### `preview_record`

Atomic capture of an animation bracketed by a trigger. Returns keyframes inline.

**Inputs:**
| Field | Type | Default | Notes |
|---|---|---|---|
| `sessionID` | string | required | |
| `trigger` | object | required | Same shape as `preview_touch` input — `{type: "tap"/"swipe"/"longPress"/"multiTouch", ...coords}` |
| `maxDurationMs` | int | 3000 | Safety cap if settle detection never fires |
| `frameCount` | int | 6 | Target keyframes to return. Hard-capped at 12 |
| `format` | enum | `"sequence"` | `"sequence"` (array of images) or `"spritesheet"` (single composite grid) |
| `quality` | float | 0.85 | JPEG quality, matches `preview_snapshot` convention |

**Pipeline:**
1. Start frame capture at ~30fps. macOS: timer-polled `Snapshot.capture` (reuses existing `bitmapImageRepForCachingDisplay` + `cacheDisplay` code path — works headless, no TCC permissions, no new frameworks). iOS: `simctl io booted recordVideo`, decoded to frames via `AVAssetReader` after stop. All frames stored as `CGImage` (platform-agnostic, no AppKit dependency in PreviewsCore).
2. Fire the trigger via the same code path as `preview_touch`, recording the tap coordinates into an in-memory touch log with monotonic timestamps.
3. Compute SSIM frame diff on 128×128 downsampled frames (not 64×64 — too coarse under font antialiasing noise; not pHash — robustness under compositing jitter matters). Store per-frame diff-to-previous in a buffer.
4. **Auto-trim** using ffmpeg-style scene-detect semantics, not cumulative-diff heuristics:
   - `motionStartFrame` = first frame where `diff > motionThreshold`
   - `motionEndFrame` = first frame where `diff < stillThreshold` sustained for ≥100ms after `motionStartFrame`
   - Fallback: if no settle, use `maxDurationMs` as end.
5. **Keyframe selection** inside `[motionStartFrame, motionEndFrame]`:
   - Pairwise threshold-gated scene detect (emit frame when diff crosses `keyframeThreshold`).
   - `minGapMs = 80` between emitted frames (flicker-fusion ~60–80ms; UIKit/SwiftUI default animation ~350ms → ~4 frames per typical transition; 50ms oversamples into 60fps noise, 200ms misses mid-transition on snappy interactions).
   - Force-emit first and last frames of the motion window.
   - If more frames cross the threshold than `frameCount`, prefer the highest-diff among them.
   - If fewer, fill by the next-highest pairwise diffs.
6. Composite touch indicators over each selected frame via CoreGraphics (`CGContext` draw on CGImage). Fading circle at tap coordinates, alpha curve ≈ 1.0 → 0 over 500ms. Simple, no AVFoundation for single-frame overlays.
7. Encode keyframes as JPEG at `quality`, return inline via `CallTool.Result(content: [.image(...), .image(...), ...])` matching `preview_snapshot`'s format. For `spritesheet` format, composite the N frames into a grid (ceil(√N) columns) and return as a single image.
8. Return structured metadata alongside images: `{durationMs, motionStartMs, motionEndMs, framesReturned, warning?}`.

**No-motion branch:** if the auto-trim step finds no frame where `diff > motionThreshold` within `maxDurationMs`, return a single frame (the last captured) plus `warning: "no motion detected within maxDurationMs — interaction may not have produced an animation"`. Do not return 6 identical frames.

**Out-of-scope parameters (deliberately omitted):**
- `outputDirectory` — matches `preview_snapshot`'s inline-only convention. If a future PR adds disk output, it should land on `preview_snapshot`, `preview_variants`, and `preview_record` together as a pure refactor with a clear rubric, not bolted onto this feature.

### `preview_record_start`

Begins session-scoped video capture. Non-blocking — returns immediately.

**Inputs:**
| Field | Type | Default | Notes |
|---|---|---|---|
| `sessionID` | string | required | |
| `codec` | enum | `"h264"` | `"h264"` or `"hevc"` |

**Behavior:**
- Opens a recording context attached to the preview session.
- macOS: starts a timer-polled `Snapshot.capture` loop at ~30fps, piping each frame (as `CVPixelBuffer` via `AVAssetWriterInputPixelBufferAdaptor`) to an `AVAssetWriter` that encodes the `.mov` live. Reuses the same `bitmapImageRepForCachingDisplay` + `cacheDisplay` code path as `preview_snapshot` — works headless, no TCC permissions, no cursor captured (view-hierarchy render, not screen capture).
- iOS: shells out to `xcrun simctl io booted recordVideo --codec <codec> <temp path>`, tracks the PID, terminates with SIGINT on stop (simctl's required signal to finalize the container).
- Attaches a middleware interceptor to the MCP tool dispatcher: every subsequent tool call against `sessionID` is appended to the active session's action log with `{tMs, tool, params, causedRecompile}`. `tMs` is wall-clock milliseconds from capture start (monotonic clock). This is one touch point at the dispatch layer — not per-tool-handler logging — so adding tool #11 later cannot forget to hook in. (Playwright's `tracing.start()` follows the same pattern for the same reason.)
- Returns `{recordingID}` as confirmation.

**Error:** if a recording is already active on this session, return error. One recording per session at a time.

**Interaction with `preview_stop`:** calling `preview_stop` on a session with an active recording implicitly finalizes the recording first. The `preview_stop` result includes the finalized recording path in addition to its normal output. No orphaned recordings, no "you forgot to call stop first" errors.

### `preview_record_stop`

Finalizes the recording. Blocking — returns when the `.mov` is fully written.

**Inputs:**
| Field | Type | Default | Notes |
|---|---|---|---|
| `sessionID` | string | required | |

**Behavior:**
1. Stop capture (iOS: SIGINT to simctl; macOS: stop the polling timer, finalize `AVAssetWriter`).
2. Composite touch indicators from the action log into the final video via a single `AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool` pass. Fading circle overlay at each tap/swipe coordinate, alpha 1.0 → 0 over 500ms. (Same approach as QuickTime Player's click rings, Loom, Appium's screenrecord plugins.) One AVFoundation export, GPU-backed, roughly real-time on Apple Silicon. No per-frame CPU decode.
3. Write final `.mov` to `NSTemporaryDirectory()/previewsmcp-<sessionID>-<uuid>.mov` (absolute path). Return the path to the caller — they can `mv` it wherever they like. Rationale: user-specified paths are footguns (permissions, accidental overwrites); working-directory output pollutes repos; temp is the Unix answer.
4. Detach the dispatcher middleware.
5. Return structured result:
   ```json
   {
     "path": "/tmp/previewsmcp-<id>.mov",
     "durationMs": 12340,
     "actions": [
       {"tMs": 0, "tool": "preview_touch", "params": {"type": "tap", "x": 100, "y": 200}, "causedRecompile": false},
       {"tMs": 850, "tool": "preview_switch", "params": {"previewIndex": 1}, "causedRecompile": true},
       {"tMs": 3200, "tool": "preview_touch", "params": {"type": "swipe", ...}, "causedRecompile": false}
     ]
   }
   ```

The action timeline is load-bearing. Playwright beat Cypress because it correlates video with a scrubbable action trace — video alone tells stakeholders *what* but not *why*. The action log is what a human (or follow-up agent) uses to understand a recorded demo.

## Architecture

```
Sources/
├── PreviewsCore/
│   └── Recording/
│       ├── FrameDiff.swift          # SSIM on 128×128 downsample, operates on CGImage (platform-agnostic)
│       ├── KeyframeSelector.swift   # scene-detect + min-gap + force-endpoints
│       ├── ActionLog.swift          # Sendable struct for timeline entries
│       ├── TouchOverlay.swift       # CoreGraphics fading-circle composite on CGImage
│       └── MovieDecoder.swift       # AVAssetReader → [CGImage] (used by iOS preview_record)
├── PreviewsMacOS/
│   └── Recording/
│       └── SnapshotRecorder.swift   # Timer-polled Snapshot.capture — atomic (CGImage buffer) or session (AVAssetWriter)
├── PreviewsIOS/
│   └── Recording/
│       └── SimctlRecorder.swift     # simctl io recordVideo wrapper, PID tracking, SIGINT finalize
└── PreviewsCLI/
    ├── MCPServer.swift              # dispatcher middleware + 3 tool handlers
    ├── MCPToolSchemas.swift          # ToolName enum + tool schema definitions
    ├── DaemonProtocol.swift          # RecordResult, RecordStartResult, RecordStopResult DTOs
    ├── RecordCommand.swift           # CLI: previewsmcp record (daemon client)
    ├── RecordStartCommand.swift      # CLI: previewsmcp record-start (daemon client)
    └── RecordStopCommand.swift       # CLI: previewsmcp record-stop (daemon client)
```

- **Platform split matches existing convention.** `PreviewsCore` holds the diff/keyframe/overlay logic — it's pure Swift with CGImage as the common frame type (CoreGraphics, no AppKit or SimulatorBridge imports). macOS capture reuses the existing `Snapshot.capture` code path (timer-polled `bitmapImageRepForCachingDisplay`). iOS capture shells out to `simctl io recordVideo`.
- **No ScreenCaptureKit.** `Snapshot.capture` already works headless, captures only the view hierarchy (no cursor, no TCC permissions), and is fast enough at 30fps for a 400×600 window (<1ms per frame on Apple Silicon). ScreenCaptureKit would add a framework dependency, TCC permission requirement, and macOS 12.3+ constraint for no measurable benefit.
- **Dispatcher middleware lives in `MCPServer.swift`** — it's a single function that wraps the existing tool dispatch table, checks for an active recording on the called `sessionID`, and appends to the action log before forwarding. No per-handler changes.
- **CLI/MCP parity** — each MCP tool has a corresponding CLI command that connects to the daemon via `DaemonClient`. Tool schemas live in `MCPToolSchemas.swift`; structured payloads use `DaemonProtocol` DTOs.

## Implementation notes

- **macOS capture is timer-polled `Snapshot.capture`.** For atomic recording (`preview_record`), the timer fires at ~30fps and stores `CGImage` frames in an in-memory buffer. For session recording (`preview_record_start/stop`), each frame is converted to `CVPixelBuffer` and piped to an `AVAssetWriter` via `AVAssetWriterInputPixelBufferAdaptor` for live `.mov` encoding. The `Snapshot` type is `@MainActor` — the timer callback must dispatch to the main actor for each capture.
- **Common frame type is `CGImage`.** `FrameDiff`, `KeyframeSelector`, and `TouchOverlay` in PreviewsCore all operate on `CGImage`, which is CoreGraphics (available on both macOS and iOS, no AppKit import). macOS: `NSBitmapImageRep.cgImage`. iOS: `AVAssetReader` → `CVPixelBuffer` → `CGImage` via `CGImage(width:height:bitsPerComponent:bitsPerPixel:bytesPerRow:space:bitmapInfo:provider:...)` or `CIContext.createCGImage`.
- **`simctl io recordVideo` finalization.** Requires SIGINT (not SIGTERM, not SIGKILL) to close the container properly. Document this in `SimctlRecorder.swift`.
- **Frame diff on iOS.** The raw simctl `.mov` must be decoded via `AVAssetReader` to get frames for SSIM. This is only needed for `preview_record` (animation mode), not `preview_record_start/stop` (which just needs the final `.mov`).
- **SSIM at 128×128.** Grayscale conversion before diff. Standard SSIM window = 8×8. Reference the canonical Wang et al. formulation; do not reinvent.
- **Touch overlays differ by tool.** For `preview_record` (keyframes): `CoreGraphics` draw directly on each selected `CGImage` — simple, no AVFoundation. For `preview_record_stop` (session `.mov`): `AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool` for a single GPU-backed export pass over the raw `.mov`.
- **Spritesheet layout.** For `format: "spritesheet"`, use `ceil(sqrt(N))` columns, row-major. Draw frame index in the corner of each cell in a contrasting color — aids LLM reasoning ("frame 3 shows...").
- **Recompile detection for `causedRecompile` flag.** `preview_configure` and any tool that changes `previewIndex`/traits triggers a recompile. The dispatcher middleware can statically tag these tools — no runtime detection needed.
- **30fps is sufficient.** For animation diff detection, 30fps gives ~10 frames across a typical 350ms SwiftUI animation — plenty for scene-detect + keyframe selection. For stakeholder demo `.mov` output, 30fps is standard for screen recordings (Loom, QuickTime both default to 30fps). 60fps would require sub-16ms capture cadence, which may stall the main run loop during complex SwiftUI layout.
- **Session `.mov` output is variable frame rate (VFR).** Timer-polled frames will not arrive at exactly 33ms intervals. `AVAssetWriter` handles this correctly — presentation timestamps are derived from `ContinuousClock.Instant` deltas, producing VFR-encoded video. This is fine for playback in QuickTime, VLC, and web browsers. Note: downstream tools that assume constant frame rate (e.g., `ffmpeg` without `-vsync vfr`) may exhibit frame drift. Document in the tool result or README if this becomes a user issue.
- **Use `DispatchSource.makeTimerSource(queue: .main)` for the capture timer.** Not `Timer.scheduledTimer` — `NSTimer` is subject to run-loop-mode coalescing during tracking events (e.g., scroll drags), which can bunch or skip frames. `DispatchSource` timers fire reliably regardless of run-loop mode.

## Testing strategy

Add to the existing test suite structure.

**Unit tests (`Tests/PreviewsCoreTests/`):**
- `FrameDiffTests.swift` — SSIM on synthetic frames (identical → 1.0, inverted → 0, known deltas).
- `KeyframeSelectorTests.swift` — given a synthetic diff-per-frame array, verify selected indices respect threshold, min-gap, forced endpoints, and fallback cases (no motion, all motion, fewer candidates than `frameCount`).
- `ActionLogTests.swift` — timeline ordering, monotonic timestamps, serialization round-trip.

**Integration tests (`Tests/MCPIntegrationTests/`):**
- `PreviewRecordMacOSTests.swift` — start a macOS preview session, call `preview_record` with a tap on a known button, assert:
  - frame count ≤ 12
  - at least one frame differs measurably from the first
  - `warning` absent
  - metadata `durationMs` within expected range
- `PreviewRecordSessionMacOSTests.swift` — start session, record, issue 3 mixed tool calls (tap, switch, configure), stop, assert action log length, order, `causedRecompile` flags, `.mov` exists at returned path and is decodable by `AVAssetReader`.
- `PreviewRecordIOSTests.swift` — same shape on the iOS simulator path (slow — boots a sim).
- **No-motion test:** trigger on a non-interactive region, assert single frame + warning.
- **Trait-change-during-recording test:** start recording, call `preview_configure` to flip colorScheme, stop recording, assert the action log contains the configure call with `causedRecompile: true` and the `.mov` is well-formed. The recompile produces a visible cut; that is expected and the action timeline is how viewers understand it.
- **Implicit-stop-on-preview_stop test:** start recording, call `preview_stop`, assert the returned result includes the finalized recording path and no recording state remains for the session.

**Fixture:** add a tiny `TestPreviews/AnimatedButton.swift` with a known animation (0.5s ease-out scale transform) so frame-diff behavior is reproducible.

## Boundaries

**Always do:**
- Auto-trim by frame diff. Never return fixed-length windows padded with still frames.
- Return inline images matching `preview_snapshot`'s convention (JPEG base64, `.image(...)` content type).
- Composite touch indicators in both tools. Without them the output is ambiguous (tap vs. background timer tick) — this is load-bearing, not gilding.
- Log every tool call during an active session to the action timeline, including ones that cause recompiles. The `causedRecompile` flag tells stakeholders *why* there's a visual gap.

**Ask first about:**
- Changing `frameCount` default above 6 or the hard cap above 12. Inline image budget in MCP responses has real limits (Claude API: 100 images/request, 5MB each post-decode, but practically >~10 images per tool result hurts context/latency). 6 keyframes × ~150KB JPEG ≈ 900KB — comfortable. Above 12, require disk output (which does not yet exist).
- Adding `outputDirectory` to *only* this tool. If users need disk output, it should land on `preview_snapshot`, `preview_variants`, and `preview_record` together as a follow-up PR with a clear rubric.
- Adding a rolling/continuous buffer. Retry-based reproduction is the current stance; only revisit if users hit non-reproducible glitches that retry can't reach.
- Capturing anything other than the preview window on macOS. Capturing the whole display risks leaking user desktop content into demo recordings.

**Never do:**
- **Gate any tool from running during an active recording.** Every tool call during a session is allowed and logged. Recompile-causing tools (`preview_configure`, `preview_switch`, `preview_variants`) produce visible cuts in the recording; the action timeline is the mechanism that explains those cuts to viewers. Hard cuts in product demos are normal — film cuts every few seconds — and legitimate flows ("here's light mode, now dark mode") must not be artificially forbidden. If the timeline is doing its job, gating is redundant; if it isn't, we should fix the timeline. Trust the timeline.
- **Write to user-specified paths.** Only `NSTemporaryDirectory()`. Permission errors, accidental overwrites, and repo pollution are all avoidable by making the caller `mv` from temp.
- **Decode-and-re-encode `.mov` frame-by-frame to composite touch overlays.** Use `AVVideoCompositionCoreAnimationTool` for a single GPU-backed export pass on session video. For keyframe overlays, use CoreGraphics (direct draw on CGImage, no AVFoundation needed).
- **Invent a semantic animation inspection story.** No CAAnimation name sniffing, no spring-curve introspection, no "which `.animation()` modifier fired." Frames only. Defer semantic tooling until there's a concrete use case and a non-private-API path.
- **Reinvent `xcrun simctl io recordVideo` on iOS.** Shell out. The interesting work is on the keyframe extraction side, not the capture side.
- **Dispatch logging per-tool.** One middleware wrapper at the dispatcher. Touching every handler is how you forget tool #11 six months from now.

## Open questions

None remaining from design review. Implementation-time discoveries (e.g., `bitmapImageRepForCachingDisplay` performance at 30fps under complex SwiftUI layouts, simctl finalization races) will be addressed as they arise.

## Prior art consulted

- `xcrun simctl io recordVideo` — flags, codec, mask options, SIGINT finalization behavior
- Xcode Simulator built-in screen record — user complaints about file size, no trim, no interaction markers
- Playwright video + trace viewer — action/video correlation is the killer feature; confirmed the dispatcher-middleware approach
- Cypress video — cautionary tale; video without action log is "I see something's wrong but can't tell what"
- Maestro record + studio — flow-file replay pattern informs action log structure
- Chromatic/Percy — visual regression explicitly freezes animations; confirms we're in uncontested territory and should not bolt assertion workflows on
- Chrome DevTools Animation panel — semantic inspection baseline we acknowledge we cannot match without private API
- Chrome DevTools Performance screenshot strip — ~100ms sampling feels slightly coarse; 80ms min-gap default is the correction
- ffmpeg `select='gt(scene,X)'` — canonical pairwise-diff scene detect; our keyframe selector matches its semantics
- Loom, QuickTime Player click rings, Appium screenrecord plugins — informs the `AVVideoCompositionCoreAnimationTool` touch overlay approach
- Anthropic computer-use / browser-use — no prior art for returning animation sequences to models; we are slightly ahead of the field, which argues for conservatism on scope

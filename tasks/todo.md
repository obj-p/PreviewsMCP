# preview_record — Task List

Companion to [`plan.md`](plan.md). Updated 2026-04-19 for daemon architecture.

## Slice 1 — Core primitives

- [x] `FrameDiff.swift` — SSIM on 128×128 grayscale downsample (Wang et al.)
- [x] `FrameDiffTests.swift` — identical → 1.0, inverted → ~0, known gradients, symmetry, different sizes
- [x] `KeyframeSelector.swift` — pairwise threshold + min-gap + forced endpoints
- [x] `KeyframeSelectorTests.swift` — all-zero, all-high, single spike, ease-out decay, budget, gap, sorted
- [x] `ActionLog.swift` — Sendable actor, Codable entries (`[String: String]` params — PreviewsCore can't import MCP)
- [x] `ActionLogTests.swift` — ordering, monotonic timestamps, JSON round-trip, flag preservation
- [x] `swift test --filter "FrameDiff|KeyframeSelector|ActionLog"` passes (21 tests, 3 suites)
- [x] `swift build` clean under strict concurrency
- [ ] **CHECKPOINT 1** — human review of core algorithms

## Slice 2 — macOS `preview_record`

- [ ] `SnapshotRecorder.swift` — timer-polled `Snapshot.capture` at ~30fps, in-memory CGImage buffer
- [ ] `TouchOverlay.swift` — single-frame CoreGraphics composite, fading circle
- [ ] `MCPToolSchemas.swift` — add `previewRecord` to `ToolName` + `mcpToolSchemas()`
- [ ] `DaemonProtocol.swift` — add `RecordResult` DTO
- [ ] `MCPServer.swift` — `handlePreviewRecord` for macOS (iOS returns "not yet supported")
- [ ] `MCPServer.swift` — emit `structuredContent` via `RecordResult`
- [ ] `RecordCommand.swift` — CLI daemon client, `--json`, `SessionTargetingOptions`
- [ ] `PreviewsMCPApp.swift` — register `RecordCommand`
- [ ] Test fixture `TestPreviews/AnimatedButton.swift`
- [ ] `PreviewRecordMacOSTests.swift` — happy path + no-motion branch (with `DaemonTestLock`)
- [ ] Verify tool appears in `ListTools` output
- [ ] Verify `previewsmcp record --help` and `--json` output
- [ ] Manual smoke test against `examples/`
- [ ] **CHECKPOINT 2** — human review of macOS UX

## Slice 3 — iOS `preview_record`

- [ ] `SimctlRecorder.swift` — fork `xcrun simctl io recordVideo`, SIGINT finalize
- [ ] `MovieDecoder.swift` — `AVAssetReader` → `CVPixelBuffer` → `CGImage` (conversion internal, returns `[CGImage]`)
- [ ] `MCPServer.swift` — fill in iOS branch of `handlePreviewRecord`
- [ ] `PreviewRecordIOSTests.swift` — happy path + no-motion (boots sim, `DaemonTestLock`)
- [ ] Manual smoke test on iOS example project
- [ ] No regression in `IOSPreviewSession` tests

## Slice 4 — macOS session recording

- [ ] `Recorder.swift` — protocol abstracting macOS / iOS session recorders
- [ ] `RecordingState.swift` — per-session actor, `isActive`, `log`, `stop`
- [ ] `SnapshotRecorder` session mode — live `AVAssetWriter` encoding of timer-polled `Snapshot.capture` feed (VFR, timestamps from `ContinuousClock.Instant` deltas)
- [ ] `PixelBufferConverter.swift` — `CGImage` → `CVPixelBuffer` via `CGContext`-backed render for `AVAssetWriterInputPixelBufferAdaptor`
- [ ] `SessionOverlay.swift` — `AVMutableVideoComposition` + `AVVideoCompositionCoreAnimationTool`
- [ ] `MCPToolSchemas.swift` — add `previewRecordStart`, `previewRecordStop` to enum + schemas
- [ ] `DaemonProtocol.swift` — add `RecordStartResult`, `RecordStopResult`, `ActionLogEntryDTO`
- [ ] `MCPServer.swift` — extract switch body into `handleTool(params:)` helper
- [ ] `MCPServer.swift` — wrap dispatch in middleware that logs to `RecordingState` when active
- [ ] `MCPServer.swift` — `recompileCausingTools` static set
- [ ] `MCPServer.swift` — `handlePreviewRecordStart` (macOS)
- [ ] `MCPServer.swift` — `handlePreviewRecordStop` (macOS, including overlay composition)
- [ ] `MCPServer.swift` — modify `handlePreviewStop` for implicit finalize
- [ ] `RecordStartCommand.swift` — CLI daemon client, imperative (stderr only)
- [ ] `RecordStopCommand.swift` — CLI daemon client, `--json` (emits path + action log)
- [ ] `PreviewsMCPApp.swift` — register both commands
- [ ] `PreviewRecordSessionMacOSTests.swift` — 3 mixed tool calls, assert action log + overlay
- [ ] `PreviewRecordSessionMacOSTests.swift` — implicit stop test
- [ ] Full `swift test` passes (middleware is global — no regressions)
- [ ] Manual smoke test: record a demo, inspect .mov in QuickTime
- [ ] **CHECKPOINT 3** — human review of session recording contract

## Slice 5 — iOS session recording

- [ ] `SessionSimctlRecorder.swift` — conforms to `Recorder` protocol
- [ ] `MCPServer.swift` — iOS branch of `handlePreviewRecordStart`
- [ ] `PreviewRecordSessionIOSTests.swift` — happy path + implicit stop (with `DaemonTestLock`)
- [ ] Manual smoke test on iOS example project

## Slice 6 — Polish

- [ ] `Spritesheet.swift` — `ceil(sqrt(N))` grid, row-major, indexed cells
- [ ] `MCPServer.swift` — wire `format: "spritesheet"` branch in `handlePreviewRecord`
- [ ] `PreviewRecordSpritesheetTests.swift` — dimensions + decoded content
- [ ] Update `README.md` tool list + CLI subcommands table
- [ ] Update `AGENTS.md` — tools, CLI table, `## Recording` section, `### Structured output` list
- [ ] `swift-format lint --strict` clean
- [ ] `swiftlint lint --quiet` clean
- [ ] Full `swift test` green

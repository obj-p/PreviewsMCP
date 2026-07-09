# #254 macOS shell-owns-agent — implementation plan

## Summary

Today on macOS each session spawns one `PreviewAgent` process that owns a real
visible `NSWindow`, renders into it, and rasters a PNG via `cacheDisplay`. When
the agent respawns (every structural edit past the generation cap, or on crash)
its window vanishes and a fresh one is recreated. That causes a visible flicker
and forced the #195 frame-restore hack (`restoreAgentWindowFrame`). #254 splits
the visible window away from the respawning renderer: a long-lived **shell**
owns one persistent window per session and hosts the agent's layer cross-process
via `CAContext`/`CALayerHost`, while the **agent** becomes a pure renderer that
respawns underneath without ever closing the window. The WindowServer holds the
last frame across the respawn gap, so the window is never blank and #195 goes
away. This mirrors the iOS shell-owns-agent topology already shipped.

Splitting the window from the renderer means display and input become two
independent cross-process crossings (iOS got both for free from FrontBoard scene
hosting; macOS does not). Both are now derisked. Display is a proven
`CALayerHost(contextID)` spike. Input is real `NSEvent` replay, confirmed by the
`previews-research` runtime capture: the shell ships event fields, the agent
synthesizes an `NSEvent` and dispatches it into its single window. Snapshots stop
going through `cacheDisplay`-to-PNG and instead read a shared `IOSurface` the
agent renders into, in-process in the shell, the same read path the iOS
streaming side uses. This plan sequences that work in four phases, each
independently shippable and verifiable, and flags the open decisions up front.

## Source-of-truth inputs

- Display + respawn derisk: memory `project_macos_agent_shell_derisk`; proven
  spike at `/tmp/layerhost-spike/{producer.m,consumer.m}`.
- Input forwarding research (committed on the `previews-research` branch):
  `research/254-macos-input-plan.md` (implementation distillation) and
  `research/254-macos-input-forwarding.md` (full findings + evidence).
- iOS precedent: memory `project_ios_agent_lifecycle` (auto-respawn, race-free
  stop, death-watch), `project_sim_streaming_architecture` (IOSurface read path).

## Target topology and how it maps to current code

Decided: a **separate per-session shell process** (matching iOS), not the
daemon. The daemon stays thin — orchestration + MCP only — and spawns one shell
per session; the shell owns the persistent window and hosts the respawning
agent. See Open Decision #1 for the rationale.

```
  daemon (PreviewHost, long-lived, MainActor)
    │  orchestration + MCP only; spawns one shell per session, tracks state
    ▼
  shell process (one per session, long-lived across agent respawns)
    │  owns the persistent NSWindow; content layer = CALayerHost(contextID)
    │  shows a fallback image until a contextID is bound
    │  captures NSEvents over the window; ships fields upstream to the agent
    │  reads the agent's IOSurface in-process for snapshots
    ▼
  agent (PreviewAgent, respawns on edits/crash)
    • renders SwiftUI body into an offscreen NSWindow (window number is stable)
    • vends a CAContext over its render layer → ships contextID to the shell
    • renders each frame into a shared IOSurface (snapshots, later streaming)
    • emits selectableRegions + control descriptions per frame (P2/P3)
    • on an input message: synthesizes NSEvent → -[NSWindow sendEvent:]
```

Current code touchpoints:
- `Sources/PreviewsCore/BridgeGenerator.swift` `renderToFileEntryPoint` (~L213-311):
  the generated agent entry that today makes the `NSWindow` + `cacheDisplay`→PNG.
  This is where the CAContext vend, the IOSurface render, and (P2/P3) the
  region/control emission replace the PNG tail.
- `Sources/PreviewsMacOS/HostApp.swift`: `jitStructuralReload` (L183),
  `restoreAgentWindowFrame` the #195 hack (L192, to delete), `jitStart` (L207),
  `agentSnapshotPath`/`agentImagePaths` the PNG snapshot source (L19, L261, to
  become an IOSurface read), `reloader(for:)` (L235), `closePreview` (L155). The
  daemon also gains: spawn/track one shell process per session, route the
  contextID/surfaceID/input messages between shell and agent.
- `Sources/PreviewsJITLink/JITStructuralReloader.swift`: `render` + respawn at
  `generationCap` (L20, L78) — the respawn point where the shell must re-host
  (rebind `CALayerHost.contextId`) instead of letting a window die.
- `Sources/PreviewAgent/main.cpp` + `Sources/PreviewsJITLinkCxx`: the ORC EPC
  transport (posix_spawn + socketpair). The upstream input message and the
  downstream contextID/surfaceID handshake ride here or on a side channel.
- New: a shell target (the per-session window-owner process), analogous to the
  iOS `ios-host/shell`. It is the consumer half of the layerhost spike.

## The four crossings

1. **Display** — agent vends a `CAContext` (`+[CAContext remoteContextWithOptions:]`,
   `.contextId` UInt32) over its root render layer; shell binds
   `CALayerHost.contextId`. WindowServer composites cross-process and holds the
   last frame when the agent dies. Re-host on respawn = rebind to the new
   agent's contextID. Private QuartzCore SPI, acceptable for a dev tool (App
   Store risk only if sandboxed). Proven in the spike.
2. **Snapshot** — agent renders each frame into a shared `IOSurface` (handed to
   the shell via mach port); shell reads pixels in-process via `IOSurfaceLock`
   → `CIImage`/`CGImage` for `preview_snapshot`. Replaces `cacheDisplay`→PNG. A
   `CALayerHost`'s pixels live server-side and cannot be read in-process, and
   `CGWindowListCreateImage` is gone in macOS 15 — so the IOSurface is required,
   not optional. NOT ScreenCaptureKit.
3. **Live input** — real `NSEvent` replay. Shell ships `{type, locationInWindow
   (window-local points, bottom-left origin), modifierFlags}` for pointer and
   `{type, characters, charactersIgnoringModifiers, keyCode, isARepeat,
   modifierFlags}` for keyboard. Agent synthesizes via `+[NSEvent
   mouseEventWith…]` / `+[NSEvent keyEventWith…]` and calls `-[NSWindow
   sendEvent:]` on its one stable window. Confirmed end-to-end in Xcode by the
   research capture (Count 0→2, TextField "xyz").
4. **Chrome + selection** (later phases) — both ride on the frame reply, no new
   transport. Chrome: agent emits `[CanvasControlDescription]` + `controlStates`,
   shell renders the controls and returns `CanvasControlEvent{controlIndex,
   event, stateBox}`. Selection: agent emits `[SelectableRegion{path, rect,
   accessibilityElement?}]`, shell hit-tests locally, no round-trip.

## Phasing (each phase ships and verifies on its own)

v1 = Phases 1+2 (decided). Phase 3 is a fast follow; Phase 4 is additive.

### Phase 0 — preserve the spike
- Move `/tmp/layerhost-spike` into the repo (e.g. `research/layerhost-spike/`)
  so the proven display primitive is not lost.
- Verify: spike builds and runs from its in-repo location.

### Phase 1 — display split + respawn re-host (the spine; retires #195)
The behavior-visible win: one persistent window that survives respawn with no
flicker, no frame-restore hack.
- New shell process: create one persistent `NSWindow` per session whose content
  layer is a `CALayerHost`; bind `contextId` on first render; rebind on every
  respawn; show a fallback image until first bind.
- Agent: in `renderToFileEntryPoint`, in addition to the existing window, create
  a `CAContext` over the hosting view's layer and report its `contextId` to the
  shell. Keep the agent window offscreen (the shell owns the visible one).
- Daemon: spawn + supervise the shell per session; relay the agent's contextID
  to the shell; death-watch (reuse the iOS lifecycle pattern).
- Reloader: at the `generationCap` respawn (`JITStructuralReloader`), hand the
  new agent's contextID to the shell rather than tearing down a window.
- Delete `restoreAgentWindowFrame` and the #195 sidecar plumbing — the window
  no longer moves, so there is nothing to restore.
- Verify: drive a structural edit that forces a respawn; the window stays open,
  holds the last frame across the gap, then shows the new content. No flicker.
  Manual run + the existing macOS reload tests (adjust for the new path).

### Phase 2 — IOSurface snapshot read (replaces cacheDisplay→PNG)
- Agent: render each frame into a shared `IOSurface` (CARenderer over an
  IOSurface-backed `MTLTexture`, per the derisk producer note), hand the surface
  to the shell via mach port.
- Shell: replace the PNG snapshot source with an in-process `IOSurfaceLock` →
  `CIImage` read; `preview_snapshot` serves that (daemon proxies to the shell,
  or the shell writes the image the daemon already tracks). Reuse the iOS read
  path (`SBCaptureFramebuffer` → `IOSurfaceLock` shape).
- Verify: `preview_snapshot` returns a correct image for a live session and
  after a respawn; double/triple-buffer so a repeated frame still refreshes
  (`IOSurfaceGetSeed` to detect new frames). Existing snapshot tests, repointed.

### Phase 3 — live input (NSEvent replay) [fast follow]
- Transport: add one upstream input message carrying the wire fields above.
- Shell: install an event monitor over the window; map the hit point into the
  agent window's local space (points, bottom-left origin); ship the fields.
  Pointer down/up/dragged/move + the key path first.
- Agent: synthesize the `NSEvent` and `-[NSWindow sendEvent:]` into its one
  window. PITFALL: never call `+[NSApplication sharedApplication]` (or otherwise
  init AppKit) off the main thread in any setup/injected code — it corrupts the
  event loop and kills the preview (cost the researcher ~6 VM runs). Validate
  drag-heavy/hover controls early.
- Verify: click a button in the shell window and the SwiftUI action runs
  (state-driven update, no respawn); type into a TextField and characters land.
  New integration test driving a counter + text field through the shell.

### Phase 4 — selection then chrome (additive, ride on the frame)
- Selection: agent emits `selectableRegions` next to the IOSurface frame; shell
  hit-tests locally and surfaces the selected `path`. Geometry-only first; AX
  element bytes deferred (residual unknown, not needed for v1).
- Chrome: agent emits `controlDescriptions` + `controlStates`; shell renders
  controls (start with `ToggleConfiguration` appearance/device) and returns
  `CanvasControlEvent`s. The `Event` raw-value strings are the one unrecovered
  detail (enum cases not exported); we define our own since we own both ends.
- Verify: a click in selectable mode reports the right `path` without running
  the action; a toggle flips appearance/device. Phase-scoped tests.

## Open decisions

1. **Shell owner: separate per-session shell process (DECIDED).** macOS daemons
   *can* own `NSWindow`s (unlike iOS, where only a foreground app can host a
   scene — the reason iOS is forced into 3 tiers). We still chose a separate
   per-session shell process, because the daemon serves MCP for every session
   and is the orchestrator: giving it N visible windows + per-session event
   monitoring + cross-process layer hosting + IOSurface reads would load its
   main run loop and erase the crash isolation between sessions (one AppKit
   stall would block MCP for everyone). A separate shell keeps the daemon thin
   and matches the iOS topology, so the lifecycle/death-watch code ports across.
2. **v1 scope: Phases 1+2 (DECIDED).** Display + snapshot are coupled — once the
   shell owns the window the agent window is offscreen, so the PNG path must
   move to IOSurface in the same change. Phase 3 (live input) is a fast follow.
3. **Wire types: our own compact codable vs re-encoding Apple's plist shapes.**
   We control both ends. RECOMMENDATION: define our own minimal types for the
   input/region/control fields; matching Apple's exact grammar buys nothing.
4. **Where the contextID/surfaceID/input messages travel:** extend the ORC EPC
   wrapper-function surface, or a small dedicated side socket between shell and
   agent. RECOMMENDATION: reuse the existing socket/EPC path the reloader
   already owns; avoid a second channel unless latency demands it.

## Risks and pitfalls

- Off-main AppKit init kills the preview (Phase 3) — see the pitfall above.
- Drag-heavy / hover / nested tracking-loop controls (NSSlider drag) may not
  complete from a synthesized `sendEvent:`; validate early, scope out if costly.
- Setting `layer.contents`/contextID twice with the same value may not refresh;
  double/triple-buffer the IOSurface and rebind deliberately on respawn.
- `CAContext`/`CALayerHost` are private SPI; fine for a dev tool, but pin to OS
  behavior we tested and keep the fallback image path (contextID is optional with
  a fallback in Xcode's own `MacOSLayerHostedPreviewViewable`).
- Display side still needs a live WindowServer/CA session; true headless on a
  detached daemon is unconfirmed — verify in Phase 1.

## Already derisked (do not re-litigate)

- Cross-process `CALayerHost(contextId)` live hosting, last-frame hold on kill,
  and respawn re-host all PROVEN on macOS 26.2 (the spike).
- Live input is real `NSEvent` (pointer AND keyboard) into one stable window via
  normal AppKit dispatch — confirmed at runtime, NOT the semantic
  `RemoteEventPayload` protocol (that serves chrome/selection/diagnostics).
- Chrome is shell-rendered from agent descriptions; selection is a shell-side
  hit-test with no round-trip — both ride on the existing frame reply.
- `NSRemoteView`/ViewBridge is a dead-end for a self-spawned agent.
- ScreenCaptureKit is rejected for snapshots; IOSurface in-process read is the path.

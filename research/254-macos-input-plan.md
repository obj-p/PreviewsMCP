# #254 macOS input forwarding — implementation plan

## Summary

Xcode's live macOS preview moves input over **two separate channels**, and
#254 should mirror that split. Live in-preview interaction (pointer and
keyboard) reaches the preview agent as ordinary `NSEvent`s delivered into one
real `NSWindow`. Everything around the preview is not an NSEvent at all: canvas
chrome (device and appearance toggles) is a semantic `CanvasControlEvent`
channel, and click-to-select is a shell-side hit-test against regions the agent
publishes with each frame. The recovery work behind this plan is recorded in
[`254-macos-input-forwarding.md`](254-macos-input-forwarding.md); this document
is the implementation-facing distillation.

The contract for #254 is therefore simple to state. The agent renders into a
real (offscreen) `NSWindow` and publishes, with every frame, the pixels plus two
small side-tables: the chrome controls to draw and the selectable regions to hit
test. The shell draws the chrome, hit-tests selection locally, and sends back
only two kinds of upstream message: synthesized `NSEvent`s for live interaction,
and `CanvasControlEvent`s for chrome. A v1 that only needs live interaction is
just the NSEvent path. Chrome and selection are additive and can land later.

## What was verified (and how)

All findings come from runtime capture and static RE inside the research VM
(Xcode 26.2, SIP and AMFI off, `post-xcode-ready` snapshot), using the
`capture-input-events` preset. The agent cannot be attached by dtrace or lldb
(task-port gate plus a `previewsd` heartbeat that SIGKILLs on a paused
breakpoint), so the runtime evidence comes from an in-agent dylib injected by
binary-patching `XCPreviewAgent` (`LC_LOAD_DYLIB` + ad-hoc re-sign), which
swizzles `-[NSApplication sendEvent:]` and `-[NSWindow sendEvent:]`. The static
evidence comes from `dyld_info -exports` over the OS-side frameworks plus
`swift demangle`.

| Area | Verdict | Evidence |
| --- | --- | --- |
| Live pointer | Real `NSEvent` (`leftMouseDown`/`Up`) into one window, runs the action (Count 0→2) | `research/scripts/data/254-s1-fixed/`, `254-s1-loc/` |
| Live keyboard | Real `NSEvent` (`keyDown`/`keyUp`), same window, same dispatch | `254-s1-loc/s1-detour.log` |
| Coordinate space | Window-local points, AppKit bottom-left origin, one stable `NSWindow` | `254-s1-loc/` |
| Canvas chrome | Separate semantic `CanvasControlEvent` channel, shell-rendered | `254-s2-chrome/control-exports.txt` |
| Selection | Shell-side hit-test against agent-published `SelectableRegion`s, no round-trip | `254-s2-chrome/control-exports.txt` |

## Architecture: two channels

```
        ┌─────────────────────────── agent (XCPreviewAgent analog) ───────────────────────────┐
        │  renders SwiftUI body into a real (offscreen) NSWindow                               │
        │  emits a render reply per frame: { IOSurface frame, [CanvasControlDescription],      │
        │                                    [SelectableRegion] }                              │
        └───────────────▲───────────────────────────────────────────────┬─────────────────────┘
                        │ upstream                                        │ downstream (render reply)
   live input:  NSEvent fields ──────► agent synthesizes +[NSEvent …]    │
   chrome:      CanvasControlEvent ───► agent applies control state       │
   selection:   (nothing)                                                 ▼
        ┌────────────────────────────────────── shell ────────────────────────────────────────┐
        │  displays the frame (CALayerHost / IOSurface), draws the chrome controls,            │
        │  routes a user gesture by canvas mode:                                               │
        │    live mode      → serialize the NSEvent fields, send upstream                      │
        │    selectable mode→ hit-test the point against [SelectableRegion] locally (no send)  │
        │    chrome control → send a CanvasControlEvent upstream                               │
        └──────────────────────────────────────────────────────────────────────────────────────┘
```

Mode is a shell-side decision. Xcode's canvas has a live/play mode and a
selectable/inspect mode; the shell chooses whether a click is forwarded as an
event or consumed for a hit-test. The agent does not decide.

## The data-flow contract

### 1. Live input — `NSEvent` replay (the v1 core)

What Xcode does, confirmed at runtime: the shell forwards the user's pointer and
keyboard interaction and the agent receives a real `NSEvent` through normal
AppKit dispatch (`-[NSApplication sendEvent:]` then `-[NSWindow sendEvent:]`).
Both pointer and keyboard travel this way, into one stable `NSWindow`.

Agent side:
- Own one real `NSWindow` (offscreen is fine; it already exists for rendering).
- On an incoming input message, synthesize the event and deliver it:
  - pointer: `+[NSEvent mouseEventWithType:location:modifierFlags:…
    windowNumber:…]` then `-[NSWindow sendEvent:]`.
  - keyboard: `+[NSEvent keyEventWithType:location:modifierFlags:…
    characters:charactersIgnoringModifiers:isARepeat:keyCode:]` then
    `-[NSWindow sendEvent:]`.

Shell side:
- Capture the gesture, map the hit point into the agent window's local
  coordinate space (points, bottom-left origin), and ship the fields below.

Wire fields (minimal):
- `type` (NSEventType), `locationInWindow` (CGPoint, window-local points),
  `modifierFlags`.
- keyboard adds `characters`, `charactersIgnoringModifiers`, `keyCode`,
  `isARepeat`. For keyboard, `locationInWindow` is not meaningful (it is a
  mouse-position artifact); drive off `keyCode`/`characters`.

Coordinate contract (settled): the agent expects window-local points in AppKit
bottom-left origin, into its single hosted window. The shell maps from its
display surface coordinates into that window's space before building the event.

Pitfalls:
- Tracking-loop controls (a slider drag, hover) are awkward from a synthesized
  `sendEvent:` because some AppKit paths assume a live mouse. Start with
  down/up/dragged/move and a real key path; revisit drag-heavy controls if they
  misbehave.
- Do not initialize AppKit from a background thread in any injected/setup code.
  Calling `+[NSApplication sharedApplication]` off the main thread corrupts the
  agent event loop and kills the preview. This cost ~6 VM runs to find.

### 2. Canvas chrome — `CanvasControlEvent`

The chrome controls (device, appearance, variants, timeline) are not views in
the agent's window. The agent **describes** them and the shell **draws** them,
so a chrome interaction can never arrive at the agent as an `NSEvent`. This is
why the channel exists.

Downstream, per render reply (agent → shell): `[CanvasControlDescription]` +
`[controlStates]`. Carried on `HostedPreviewReply` and `StaticPreviewReply`
(`controlDescriptions: [CanvasControlDescription]`, `controlStates:
[PlistValueBox]`); incremental state on `ShellUpdatePayload.controlStates`.

`CanvasControlDescription`:
- `controlType: ControlType`, `modifiers: Modifiers`, `thumbnailGeometry:
  ThumbnailGeometry?`, plus a static `.disabled`.
- `ControlType` is one of:
  - `ToggleConfiguration(sfSymbolName: String, title: String,
    supportsInteractionEvents: Bool)` — device/appearance toggles.
    `supportsInteractionEvents` gates whether the control emits events
    (interactive) or is display-only.
  - `GridConfiguration(sections: [Section(title, items: [Item(title)])])` —
    device/variant pickers.
  - `TimelineConfiguration(stops: [TimelineStop(id, name, sfSymbolName?)],
    allowShuffle: Bool)` — animation scrubber.

Upstream, on interaction (shell → agent): `CanvasControlEvent`:
- `controlIndex: Int` (which control, indexing the description list),
- `event: Event` (a `RawRepresentable` String enum),
- `stateBox: PlistValueBox` (the new state).
- generic ctor: `init<A: PropertyListRepresentable & Equatable>(event:,
  controlIndex:, state:)`.

Residual unknown: the `Event` raw-value strings. The enum cases are not exported
symbols (they live in metadata), and the only way to enumerate them is lldb on
the getter, which the agent's task-port gate blocks. Not needed for v1; recover
later by other means if we ship rich chrome.

### 3. Selection — shell-side hit-test (no round-trip)

A selection is resolved by the shell hit-testing the click against regions the
agent publishes with each frame. There is no `hitTest`/`selectAt` request back
to the agent (searched the exports), so selection costs nothing upstream.

Per render reply (agent → shell): `selectableRegions: [SelectableRegion]`,
carried on `RenderPayload`, `IOSurfacePayload`, and the geometry-only
`GeometryPayload`.

`SelectableRegion`:
- `path: String` — the view identity used for selection,
- `rect: CGRect` — the hit area in canvas coordinates,
- `accessibilityElement: Data?` — an archived AX element (optional),
- `scaledBy(Double)` — scale the region for zoom/HiDPI.

Agent side: emit one `{rect, path, AX?}` per selectable view alongside the
frame. Shell side: on a click in selectable mode, hit-test the point against the
`rect`s, take the `path` as the selection identity, and drive the inspector.

Residual unknown: the exact bytes of the `accessibilityElement` archive
(`NSAccessibility` element encoding). Only needed if we mirror Xcode's AX-driven
selection; geometry-only selection works without it.

## How this rides on the planned display path

#254's display work already plans a shared `IOSurface` (for snapshots and
selection) and a `CAContext`/`CALayerHost` live-hosting path (see the
shell-owns-agent derisk). The two input side-tables attach directly to that:

- The frame payload is exactly the place chrome and selection live in Xcode.
  `IOSurfacePayload` already carries `selectableRegions`, so #254's frame
  message gains a `selectableRegions` field and (when we add chrome) a
  `controlDescriptions` + `controlStates` field.
- No new transport is required for chrome or selection. They are fields on the
  reply that already carries the frame. Only live input needs an upstream
  message, and that is small (the `NSEvent` fields above).

## Suggested phasing

- **Phase 1 — live input (Option B).** Upstream `NSEvent` fields, agent
  synthesizes and dispatches into its window. Ship pointer down/up/drag/move and
  the key path. This alone gives a live, clickable, typable preview.
- **Phase 2 — selection.** Agent emits `selectableRegions` on the frame; shell
  hit-tests locally and reports the selected `path`. Geometry-only first; add AX
  later if needed.
- **Phase 3 — chrome.** Agent emits `controlDescriptions`/`controlStates`; shell
  renders the controls and returns `CanvasControlEvent`s. Start with
  `ToggleConfiguration` (appearance/device) since it is the common case.

## Open decisions for #254

- Whether v1 ships only Phase 1, or also Phase 2 selection. Selection is cheap
  (no upstream traffic) but needs the agent to compute regions.
- Whether to define our own compact wire types or to re-encode Apple's plist
  shapes 1:1. We control both ends, so a compact `Codable`/plist of the fields
  above is enough. Matching Apple's exact grammar buys nothing here.
- Drag-heavy and hover controls under synthesized `sendEvent:` are the main
  technical risk to validate early in Phase 1.

## References

- Findings + method: [`254-macos-input-forwarding.md`](254-macos-input-forwarding.md).
- Evidence: `research/scripts/data/254-s1-fixed/`, `254-s1-loc/`,
  `254-s2-chrome/` (the demangled control + region exports are in
  `254-s2-chrome/control-exports.txt`).
- Capture harness: the `capture-input-events` preset in
  `research/vm/Sources/previewsvm/SetupCommand.swift`.
- Injected probe: `research/scripts/data/254-s1/event-detour.c` (arm64
  prologue-detour + `sendEvent:` swizzle).

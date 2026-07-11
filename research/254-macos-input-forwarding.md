# Research plan: macOS cross-process input forwarding for #254

Status: research brief for the `previews-research` session. 2026-06-22.
Owner of the implementation: #254 (port the iOS shell-owns-agent topology to macOS).
This is NOT a handoff. It is a scoped research task with verification criteria.

## Summary

#254 splits the macOS preview into a long-lived **shell** window that hosts a
short-lived **agent** process (the renderer that respawns on edits). On macOS,
display and input are two independent cross-process crossings (iOS bundled both
via FrontBoard scene hosting, which has no macOS equivalent). **Display is already
derisked**: a proven `CAContext`/`CALayerHost(contextID)` spike hosts the agent's
live layer in the shell window, holds the last frame when the agent dies, and
re-hosts a respawned agent by rebinding the contextID. The agent will also render
each frame into a shared IOSurface the daemon reads in-process for snapshots. The
one remaining unknown is **input**: how does the shell get a click, drag, hover,
keypress, or canvas-control toggle to act on the agent's view tree, when the shell
window only hosts a server-side composited layer and owns no view objects?

This plan does not assume the answer is "serialize NSEvents." Static RE of Xcode
26.2's own preview frameworks shows Apple uses a **semantic event protocol**, not
raw event replay: a dedicated `previewRemoteEvents` message stream carrying a
`RemoteEventPayload`, a separate `canvasControlEvents` stream for canvas chrome
(device toggles, Dynamic Type, etc.), and `SelectableRegion(path:rect:accessibilityElement:)`
records that tell the canvas what is hittable and carry an accessibility blob. The
research goal is to recover that protocol's actual encoding via runtime capture,
decide whether we adopt Apple's semantic model or fall back to our own NSEvent
serialize/replay, and hand #254 a concrete, verified input design.

## What is already known (do not re-derive)

- Source of truth: memory `project_macos_agent_shell_derisk` and the archived
  handoff `2026-06-22-macos-agent-shell-254-derisk.md`.
- Display + respawn primitive PROVEN: `/tmp/layerhost-spike/{producer.m,consumer.m}`
  (build line in that handoff). `CAContext +remoteContextWithOptions:` -> `.contextId`,
  consumer binds `CALayerHost.contextId`. WindowServer holds last frame on producer
  kill. Re-host = rebind contextId.
- Snapshot path SETTLED: agent renders into a shared IOSurface; daemon reads pixels
  in-process via `IOSurfaceLock` -> `CIImage`/`CGImage`. NOT ScreenCaptureKit. Same
  read path as the iOS streaming side (`SBCaptureFramebuffer` ->`IOSurfaceLock`).
- `NSRemoteView`/ViewBridge is a DEAD-END for a self-spawned agent (private, gated
  to the `.appex` NSExtension model, blocks host-side screenshotting). Do not pursue
  unless static RE here surprises us.

## Decisive static-RE evidence (Xcode 26.2, already gathered)

Frameworks: `/Applications/Xcode-26.2.0.app/Contents/SharedFrameworks/Previews*.framework`.
Method used: `nm -gU <binary> | swift demangle` + `strings`. Findings:

- **`PreviewsMessagingHost.MessageStreamInstanceIdentifier`** enumerates the cross-process
  message streams. The input-relevant ones:
  - `previewRemoteEvents`  <- the live input/event channel (carries `RemoteEventPayload`).
  - `canvasControlEvents`  <- canvas chrome controls (semantic, not raw input).
  - `macOSSnapshots`       <- the snapshot channel (confirms our IOSurface plan).
  - also: `registryRuntimeEvents`, `cFunctionStreamingOutput`, `nsPreviewSuppressedPresentations`.
- **`RemoteEventPayload`** (in `PreviewsMessagingHost`): `PropertyListRepresentable`,
  with a nested `DiagnosticsBehavior` enum. Its fields are NOT exposed as public
  getters; only `init(propertyListValue:)` and `propertyListValue.getter`. So the
  actual event encoding lives inside the property-list dict and is opaque to static
  symbol dumps. **Recovering those dict keys is the central task of this research.**
- **`CanvasControlEvent(event:controlIndex:state:)`** with `Event(rawValue: String)`,
  and `CanvasControlDescription.ControlType.ToggleConfiguration(sfSymbolName:title:supportsInteractionEvents:)`.
  So canvas chrome is a typed semantic event keyed by control index + a plist state
  box, NOT a synthesized click on a button.
- **`SelectableRegion(path: String, rect: CGRect, accessibilityElement: Data?)`**
  carried on `RenderPayload`, `IOSurfacePayload`, `GeometryPayload`. `path` is a
  view-tree path string; `accessibilityElement` is a serialized AX element. The
  canvas hit-tests a click against these rects to resolve a semantic target. This
  strongly implies selection/identification goes through AX + path, not pixel-space
  event replay.
- **Host-side viewables** (in `PreviewsDeveloperTools`) confirm the consumer shapes:
  `MacOSLayerHostedPreviewViewable(contextID:UInt32?, ..., selectableRegionsInPixelSpace:, fallbackImage:)`
  and `IOSurfacePreviewViewable(surfaceID:UInt32, ..., selectableRegionsInPixelSpace:)`.
  Note `contextID` is optional with a `fallbackImage` — this is exactly the never-blank
  story (show the still image until a contextID is bound).

Negative evidence worth stating: a `strings` scan for `mouseDown/mouseUp/mouseDragged/keyDown/scrollWheel`
on `PreviewsMessagingHost` found NONE. That is consistent with "no raw NSEvent
names on the wire" but is not proof; the runtime capture below settles it.

## Central hypothesis to confirm or refute

**H:** Xcode forwards input as a small semantic protocol over `previewRemoteEvents`
(a `RemoteEventPayload` plist) plus `canvasControlEvents`, and resolves clicks
against `selectableRegions` (path + AX), rather than serializing/replaying raw
`NSEvent`s into the agent's window. Live UI interaction (e.g. tapping a real
SwiftUI `Button`, dragging an `NSSlider`) is therefore either (a) driven by the
semantic payload into the preview runtime, or (b) NOT actually live in Xcode's
canvas for arbitrary controls (Xcode's canvas is largely selection + chrome, with
"live" interaction being a limited mode).

Why the (a)/(b) distinction matters for #254: it sets our scope. If Xcode itself
does not do general live interaction, we should not over-invest either; a semantic
selection + canvas-control model may be the right product, with full live input as
a later, explicitly-scoped add.

## Subproblems and verification criteria

### S1. Recover the `RemoteEventPayload` wire encoding (highest value)
Capture the actual property-list dict Xcode sends on `previewRemoteEvents` during a
real interaction with a macOS preview, and decode its keys (event kind, location,
modifiers, target path, phase, etc.).

- Method: in the research VM (see `project_vm_capture_baseline`), drive Xcode 26.2
  with a trivial macOS preview, then either (i) dtrace/lldb on `XCPreviewAgent` and
  the Xcode canvas process around `RemoteEventPayload.init(propertyListValue:)` /
  `.propertyListValue.getter` and dump the plist, or (ii) interpose the transport
  send/recv (the `Transport.activate(forReceivingEvents:)` async stream) and log
  payloads. Prefer lldb breakpoints that print the `PropertyList` argument.
- Verify: we have a labeled dump of >=4 distinct interactions (click, drag, key,
  hover or scroll) showing the dict keys and value types for each. Done when we can
  describe the event grammar well enough to re-encode it.

### S2. Map `canvasControlEvents` and `CanvasControlDescription`
Determine what canvas controls exist (the `controlIndex` space), their `Event`
raw-value vocabulary, and how `ToggleConfiguration.supportsInteractionEvents` gates
behavior.

- Method: same VM; enumerate `CanvasControlEvent.Event(rawValue:)` candidates via
  lldb on the getter, and observe which controls Xcode renders for a macOS preview.
- Verify: a table of control types -> events -> state payloads. Done when we can say
  whether our shell needs this channel for v1 (likely yes for device/appearance
  toggles) or can defer it.

### S3. Confirm the selection/hit-test path
Determine whether a click in Xcode's canvas resolves via `selectableRegions`
(path + `accessibilityElement`) to a selection, and whether that is separate from
"live" interaction.

- Method: VM; click inside vs outside a region, watch which stream fires
  (`previewRemoteEvents` vs a selection channel) and whether the AX element is used.
- Verify: a one-paragraph statement of "click -> selection" vs "click -> live event"
  with evidence, plus how `selectableRegions` are produced agent-side (so #254's
  agent can produce them too).

### S4. Decide the #254 input mechanism (the actual deliverable)
Given S1-S3, choose one and justify against the constraints (self-spawned agent, no
Accessibility entitlement desired, no sandbox today, must survive respawn):

- Option A — adopt Apple's semantic model: shell ships a `RemoteEventPayload`-like
  plist over our existing ORC/socket transport; agent applies it to the preview
  runtime; selection via our own `selectableRegions`. Pro: matches Xcode, robust to
  layer hosting (no real window for events to land on). Con: must reimplement the
  grammar and the agent-side application.
- Option B — fall back to NSEvent serialize/replay: shell captures `NSEvent`s,
  ships fields, agent synthesizes via `+[NSEvent mouseEventWithType:...]` +
  `-[NSWindow sendEvent:]` on its own offscreen window. Pro: general, no protocol RE.
  Con: hover/tracking-loop controls (NSSlider drag) are hard from injected
  `sendEvent:`; coordinate spaces and `windowNumber` are process-local; the agent
  window is offscreen so some AppKit paths may not engage.
- Option C — hybrid: semantic for selection + canvas chrome (A), NSEvent replay only
  for the narrow "live interaction" mode if we even ship it (B).
- Verify: a recommendation with the failure modes of the rejected options named, and
  a rough effort estimate for the chosen one. This is what #254's implementation plan
  consumes.

## Deliverable

A short report appended to this file (or a sibling under `research/`) covering:
S1 event grammar dump, S2 control table, S3 selection-vs-live verdict, and the S4
recommendation. Plus: whether the `/tmp/layerhost-spike` display spike should be
moved into the repo for reference.

## Capture harness (implemented)

A `capture-input-events` preset (`research/vm/Sources/previewsvm/SetupCommand.swift`)
drives Xcode 26.2 in the `post-xcode-ready` VM over VNC. Run:

```
research/vm/.build/debug/previewsvm setup ~/.previews-research-vms/research.bundle \
  --preset capture-input-events --transport vnc --retry 1 \
  --restore-from post-xcode-ready --output-dir research/scripts/data/254-s0-capture
```

What it took to make the canvas render and the preview run in-VM (each was a
real blocker, documented so we don't re-discover them):

- **Display must be 1× to give the canvas room.** The VM display was 1920×1080
  @220ppi → macOS HiDPI 2× → only ~640×360 usable points → the canvas pane
  collapses to zero width and never shows a preview. Added
  `VMConfiguration.DisplayResolution` with a `.roomy` mode (1280×720 @96ppi,
  same RFB pixel size, 1× scaling, 4× the usable point area). Only this preset
  uses `.roomy`; other presets keep `.standard` so their calibrated coords are
  untouched. RFB framebuffer size is now read from the handshake
  (`RFBClient.framebufferSize`) and used for OCR→click mapping instead of a
  hardcoded 1280×720.
- **Canvas open:** at 1× the canvas is open by default for a SwiftUI file. Do
  NOT use Cmd+Option+Return — Xcode 26 rebound it to Coding Intelligence (a
  modal that eats all later keystrokes; dismiss it via OCR-click "Remind Me
  Later", Escape does not close it). The Editor-menu and Help-search paths are
  flaky (OCR groups the whole menu bar into one block; Help→Down→Return hits a
  Help topic).
- **Preview activation:** the canvas being visible does NOT start the pipeline.
  XCPreviewAgent only spawns after **Cmd+Option+P (Resume Preview)**. With that,
  `pgrep XCPreviewAgent` → AGENT_UP and the preview renders.
- **OCR button-click disambiguation:** once the preview renders, the rendered
  "Increment" sits in the canvas (high framebuffer x, ~1039/1280) while the
  source `Button("Increment")` is center-left; OCR resolves to the rendered one.
  Before the preview renders, OCR matches the source instead — so a successful
  rendered-button click is itself a signal the pipeline is live.

## S0 result — macOS canvas IS live (hypothesis branch (a), confirmed)

Fixture: a `#Preview` of a `@State var count` view with `Text("Count: \(count)")`
and `Button("Increment") { count += 1 }`. The harness OCR-clicked the rendered
button twice. The canvas readout went **Count: 0 → Count: 2** (screenshots in
`research/scripts/data/254-s0-capture/attempt-1/`: `09-05-count-before` … `11-07-after-click-2`).

So Xcode's macOS preview canvas executes real live interaction: a click on the
rendered control runs the SwiftUI action and the `@State`-driven view updates in
place (no agent respawn needed for state-only changes). This settles the (a)/(b)
question from the hypothesis: live interaction is genuine, not selection-only.

Implication for #254: a live input path is in scope (it is a real Xcode feature,
not an illusion), so S1 (recovering the `previewRemoteEvents` / `RemoteEventPayload`
wire encoding) is worth doing in full, and Option A (semantic protocol) or C
(hybrid) — not just selection + chrome — should be on the table for S4.

## S1 progress — runtime capture path (dtrace ruled out)

- The agent reliably spawns (Cmd+Option+P) and clicks land on the rendered
  button, so events DO flow on a real interaction.
- **dtrace pid provider cannot attach to XCPreviewAgent**: `dtrace: failed to
  grab pid <n>: (ipc/?) unknown subsystem error`, even with SIP off + AMFI off.
  This confirms the W3 note that the pid provider is gated by a signed-binary
  check separate from SIP. So dtrace is OUT for the agent; the in-agent
  interposer (LC_LOAD_DYLIB binary patch, proven by W3) is the only runtime
  path that runs inside the agent's address space.
- The payload is Swift-encoded: `RemoteEventPayload.init(propertyListValue:)`
  (mangled `_$s21PreviewsMessagingHost18RemoteEventPayloadO17propertyListValueAC0a10FoundationC008PropertyH0V_tKcfC`)
  on the receiver, `RemoteEventPayload.propertyListValue.getter` on the sender.
  `PreviewsMessagingHost`/`PreviewsFoundationHost` import NO CFPropertyList/xpc
  serialization symbols, so there is no easy C chokepoint; the dict lives behind
  `PropertyList.serializableDictionary : [String:Any]` and a `PropertyListArchiver`
  type. Capturing the exact keys needs in-agent Swift hooking (an arm64 prologue
  detour on the init symbol that then reads `serializableDictionary` and writes a
  plist) or tapping `LazyPropertyList`'s backing bytes — a real engineering task,
  not a one-liner.

## S1 — receiver is PreviewsMessagingOS (NOT …Host); Option C de-risked

Important correction to the static-RE section above: those symbols
(`PreviewsMessagingHost.*`) are the **sender/Xcode** side. The **agent**
(XCPreviewAgent, the receiver) loads the **OS** variants from
`/System/Library/PrivateFrameworks/`: `PreviewsMessagingOS`,
`PreviewsFoundationOS`, plus `PreviewsInjection`, `XOJITExecutor`,
`PreviewsServices`, `PreviewsOSSupport(UI)`. The types mirror the Host side
1:1 — `PreviewsMessagingOS` exports `RemoteEventPayload.init(propertyListValue:)`,
`RemoteEventRequestPayload`, `CanvasControlEvent` (+ `.Event` rawValue enum),
`SelectableRegion`, `RenderPayload`/`IOSurfacePayload`/`GeometryPayload`
(all carrying `[SelectableRegion]`), `HostedPreviewReply`/`StaticPreviewReply`
(carrying `controlDescriptions` + `controlStates`). Dump the OS-side exports
with `dyld_info -exports <path>` (reads the shared cache; the on-disk file does
not exist). The receiver-decode symbol is
`$s19PreviewsMessagingOS18RemoteEventPayloadO17propertyListValueAC0a10FoundationC008PropertyH0V_tKcfC`.

Option C de-risk (PASSED): the W3 LC_LOAD_DYLIB patch injects a probe dylib
into XCPreviewAgent (confirmed `LOADED pid=… exe=…/XCPreviewAgent`), and from
in-process `dlsym(RTLD_DEFAULT, …)` resolves all four OS-side init symbols to
non-null addresses (`resolved=4/4`, e.g. RemoteEventPayload.init at 0x27f7…).
So an in-agent arm64 prologue detour on `RemoteEventPayload.init(propertyListValue:)`
is feasible. Next: detour that symbol, and in the hook read the incoming
`PreviewsFoundationOS.PropertyList` via its `serializableDictionary : [String:Any]`
getter, bridge to NSDictionary, and write a plist per event → the exact wire
grammar (S1 deliverable). Probe + injection live in the `capture-input-events`
preset; evidence in `research/scripts/data/254-s1-probe/`.

## S1 detour — mechanism PROVEN, target symbol not on the click path

The in-agent arm64 inline detour works. Evidence (one run):
`LOADED pid=… → RESOLVED target=0x… → INSTALLED rc=0` on
`RemoteEventPayload.init(propertyListValue:)`, plus an **arc4random canary**
(same detour, called by us) that fired `CANARY arc4random hook fired #1`. So
`vm_protect(VM_PROT_COPY)` text patching of the dyld shared cache + the
relocated-prologue trampoline + the register-preserving asm stub all function
on Apple Silicon with SIP+AMFI off.

But clicking the rendered button (clicks confirmed landing at fb (1039,409),
same agent pid that installed the hook) produced **no HOOK** on
`RemoteEventPayload.init`. Since the mechanism is proven, the conclusion is that
the live click is NOT decoded through that exported symbol in the agent — most
likely `init(propertyListValue:)` is **inlined** into the PreviewsMessagingOS
stream-decode path (the exported symbol survives for the protocol witness /
external callers, but the runtime decode uses an inlined copy), or the pointer
event decodes via a different entry than `RemoteEventPayload`.

Next options (inlining-proof, in rough order): (1) detour the **protocol-witness**
`PropertyListRepresentable.init(propertyListValue:)` for RemoteEventPayload
(called indirectly via the witness table, so not inlined) — quick, reuses the
detour infra; (2) detour the **stream-receive** boundary in PreviewsMessagingOS
(the OS-side `AsyncMessageStream`-equivalent that delivers a `LazyPropertyList`
per message) and dump every message, filtering for the event one; (3) byte-tap
the transport receive (C ABI, inlining- and patch-proof) and decode offline.
Also worth a parallel check: confirm whether the agent instead receives a
synthesized real event (NSEvent/CGEvent) for in-preview interaction, with the
semantic `previewRemoteEvents`/RemoteEventPayload path reserved for the sender.

## S1 — four semantic payload inits are silent on a click (hypothesis pivot)

Multi-slot detour run (mechanism re-confirmed: arc4random canary fired). All
four exported `init(propertyListValue:)` decoders installed rc=0 in the agent:
`RemoteEventPayload` (0x279825394), `RemoteEventRequestPayload` (0x279824350),
`CanvasControlEvent` (0x279782ae8), `SelectableRegion` (0x2797b2208). Clicking
the rendered button produced **HOOK on none of them** (only the canary).

So the live in-preview pointer interaction is NOT decoded through the semantic
PreviewsMessagingOS plist types in the agent. This pivots the working answer:
the semantic `previewRemoteEvents` / `RemoteEventPayload` protocol (proven on
the Host/sender side) is likely NOT the channel for ordinary pointer events
into a live preview. Leading hypothesis now: the click is delivered to the
agent's hosted view as a **synthesized real event** (AppKit/SwiftUI event
path), with the semantic protocol reserved for specific remote events / canvas
chrome. (Less likely but possible: all four inits are inlined and an unexported
decode runs — but four independent types inlining together is unlikely.)

Next discriminators (cheap → robust): (1) hook ObjC `-[NSApplication sendEvent:]`
/ `-[NSView mouseDown:]` / hit-test in the agent (ObjC swizzle, no arm64
detour) — if these fire on a canvas click, real-event delivery is confirmed;
(2) byte-tap the agent's IPC receive (mach_msg / xpc / read, C ABI,
type-and-inlining-proof) and dump what arrives on a click, decode offline.
This refines the S4 recommendation either way: if macOS forwards real events,
#254's live-input path is NSEvent-replay-shaped (Option B), not a semantic
plist (Option A) — the opposite of what the static Host-side RE suggested.

## S1 BLOCKER — agent re-sign breaks the live preview (prior hook results void)

A swizzle-only run (zero arm64 text patching, just clean ObjC
method_setImplementation on sendEvent:) STILL showed the canvas "Cannot
preview" error and the click OCR fell back to the source line (no rendered
button). So the detour was never the culprit. The common factor across all
injected runs is the agent prep: `mach-o-add-dylib` (LC_LOAD_DYLIB) + ad-hoc
`codesign --force --sign - --entitlements <get-task-allow-only>`. Re-signing
with ONLY get-task-allow strips the agent's real entitlements (and changes its
cdhash), which breaks the preview pipeline — XCPreviewAgent can no longer
render. The S0 runs worked because they never injected.

Consequence: ALL the "silent hook" S1 results above (4 semantic inits silent,
sendEvent: silent) are FALSE NEGATIVES — the preview was dead, so no input
events ever flowed. They prove nothing about the click path.

Unblock (next): inject WITHOUT breaking the preview. Re-sign preserving the
agent's FULL original entitlements plus get-task-allow — extract them first via
`codesign -d --entitlements - --xml <agent>` or `ldid -e` (the CMS-blob caveat
in the W3 notes can be worked around with the xml form), merge get-task-allow,
re-sign with the complete set. Or test a no-re-sign path: with AMFI off, a
binary whose signature was invalidated by the LC_LOAD_DYLIB edit may still
execute AND keep its entitlements honored — verify empirically. Verification:
after injection, the canvas renders the counter and a click increments it
(same check S0 used) AND the dylib's hooks fire. Only then are hook results
trustworthy. (W3's JIT capture used the same get-task-allow-only re-sign and
"worked" because it traced compile/respawn on edits, not live interactive
rendering, so it never needed a fully-live preview.)

## S1 RESOLVED — live pointer input is a REAL NSEvent, not the semantic protocol

The earlier "agent re-sign breaks the preview" conclusion was wrong. The real
cause was a bug in my own probe: `install_objc_probes` called
`+[NSApplication sharedApplication]` from the background installer thread, which
initialized NSApplication off the main thread ("GetMainEventLoop returned a
bogus value; Carbon Thread Manager imprinted on the main thread") and corrupted
the agent's event loop, killing the preview. The agent re-sign (ad-hoc,
get-task-allow) is FINE. Removing that one call fixed everything.

With the probe fixed (class-level swizzle only, no instantiation), the injected
agent renders a LIVE preview and a click increments the counter (Count 0 → 2),
AND the swizzled event hooks fire per click:

```
NSAppSendEvent type=1   (leftMouseDown)   NSWinSendEvent type=1
NSAppSendEvent type=2   (leftMouseUp)      NSWinSendEvent type=2
```

So the verdict: **Xcode forwards an in-preview pointer interaction to the agent
as a real `NSEvent`** (leftMouseDown=1 / leftMouseUp=2), delivered through the
agent's normal AppKit dispatch (`-[NSApplication sendEvent:]` →
`-[NSWindow sendEvent:]`). It is NOT carried by the semantic
`RemoteEventPayload` / `previewRemoteEvents` plist protocol — all four OS-side
payload decoders stayed silent on a click (now a trustworthy result, since the
preview was live this time). This **refutes hypothesis H for pointer input**.
The static-RE semantic protocol (Host side) and `SelectableRegion`/AX records
are real but serve other roles (canvas chrome via `canvasControlEvents`,
selection, keyboard/diagnostics) — not the live pointer path.

Method that settled it: `capture-input-events` preset →
`research/scripts/data/254-s1/event-detour.c` injected into XCPreviewAgent via
LC_LOAD_DYLIB. The arm64 prologue-detour mechanism is proven (arc4random
canary) but unused for the verdict; the ObjC `sendEvent:` swizzle is what
caught the real events. Evidence: `research/scripts/data/254-s1-fixed/`.

## S4 recommendation for #254 (the deliverable)

Adopt **Option B — NSEvent serialize/replay — for live pointer input**, because
that is exactly what Xcode itself does: the shell captures `NSEvent`s over the
hosted layer and ships their fields to the agent, which synthesizes an
`NSEvent` (`+[NSEvent mouseEventWith…]`) and delivers it to its hosted view via
`-[NSWindow sendEvent:]` / the responder chain. We confirmed the agent's view
processes real events end to end (state updates, no respawn). Pair this with a
**hybrid (Option C)** for the non-pointer surfaces the semantic protocol does
own: canvas chrome (device/appearance toggles) maps to `CanvasControlEvent`
over a control channel, and selection/identification uses our own
`selectableRegions` (path + AX) — but those are secondary to shipping live
pointer input.

Rejected — Option A (semantic `RemoteEventPayload` plist for pointer input):
refuted by the runtime capture; the agent does not decode pointer clicks that
way. Pursuing it would reimplement a protocol Xcode does not use for this path.

## S1 refinement RESOLVED — coordinate space + window + keyboard path

A follow-up probe extended the `sendEvent:` swizzle to log
`-[NSEvent locationInWindow]` (CGPoint, returned in d0/d1 via plain
`objc_msgSend` on arm64, NOT `_stret`) and `-[NSEvent windowNumber]`, and added
a `TextField` + `.type("xyz")` step to exercise the keyboard path. Result
(`research/scripts/data/254-s1-loc/`, preview confirmed live: Count → 2 and the
field shows `xyz`):

```
type=1/2 (mouse down/up)  loc=160.9,151.0  win=50   ← Increment button clicks
type=5/8/9 (move/enter/exit) loc=90.9,95.0 win=50   ← over the TextField
type=10/11 (keyDown/keyUp) loc=0.0,332.0  win=50    ← the xyz typing
```

Three settled facts for #254's Option-B implementation:

1. **One stable real `NSWindow` (number 50) receives every event** — pointer and
   keyboard alike. The agent owns a single real window; synthesize events into it.
2. **Pointer events carry real window-local coordinates** (`locationInWindow`,
   AppKit bottom-left origin, in points): clicks land at sane positions inside
   the preview content bounds. So #254 maps shell-side hit coordinates into this
   window's local space and builds the `NSEvent` with that `locationInWindow`.
3. **Keyboard also flows as real `NSEvent`s** — `keyDown`/`keyUp` (type 10/11)
   dispatch through both `-[NSApplication sendEvent:]` and `-[NSWindow
   sendEvent:]`, same path as pointer. This generalizes the S1 verdict: *all*
   live input is real NSEvents, so Option B covers keyboard too (build with
   `+[NSEvent keyEventWith…]`). Key events' `locationInWindow` is not meaningful
   (mouse-position artifact); use `characters`/`keyCode`, not location.

This closes the coordinate contract. Both `sendEvent:` entry points fire for
every event, confirming full normal AppKit dispatch into the agent's window.

## S2 RESOLVED — canvas chrome is a separate semantic control channel

Verdict: canvas chrome (device/appearance/variants/timeline controls) is NOT an
NSEvent path. It is a fully separate semantic channel where **the agent
describes the controls and the shell (Xcode) renders them**, structurally
distinct from the S1 live-pointer path. This is settled by static RE of the
`PreviewsMessagingOS` exports (`research/scripts/data/254-s2-chrome/`,
`dyld_info -exports` + `swift demangle`):

- Both render replies carry the chrome: `HostedPreviewReply` and
  `StaticPreviewReply` each expose `controlDescriptions: [CanvasControlDescription]`
  + `controlStates: [PlistValueBox]`, and `ShellUpdatePayload` carries
  `controlStates: [PlistValueBox]?`. So the agent ships, per render, the set of
  controls to draw plus their current state.
- The shell draws those controls (they are never views in the agent's window)
  and, on interaction, sends back a `CanvasControlEvent`. Because the agent
  renders no chrome, a chrome interaction *cannot* arrive as an NSEvent into the
  agent — which is why this channel is needed in addition to Option B.

Control table (the `controlIndex` space + event/state vocabulary):

- `CanvasControlEvent` (shell → agent): `controlIndex: Int` (which control),
  `event: CanvasControlEvent.Event`, `stateBox: PlistValueBox` (the new state).
  `Event` is a `RawRepresentable` **String** enum (`init(rawValue: String)`,
  `rawValue: String`; conforms Equatable/Hashable). The generic ctor is
  `init<A: PropertyListRepresentable & Equatable>(event:controlIndex:state:)`.
  The exact `Event` raw-value strings are NOT exported (enum cases live in
  metadata, not named symbols) — the one residual unknown, and the brief already
  flagged it as lldb-only, which the agent's task-port gate blocks.
- `CanvasControlDescription` (agent → shell, one per control): `controlType:
  ControlType`, `modifiers: Modifiers`, `thumbnailGeometry: ThumbnailGeometry?`,
  plus a static `.disabled`. `ControlType` is an enum of three configs:
  - `ToggleConfiguration(sfSymbolName: String, title: String,
    supportsInteractionEvents: Bool)` — device/appearance toggles. The
    `supportsInteractionEvents` flag is the brief's gate: it marks whether the
    control emits `CanvasControlEvent`s (interactive) vs. is display-only.
  - `GridConfiguration(sections: [Section(title, items: [Item(title)])])` —
    pickers (device/variant grids).
  - `TimelineConfiguration(stops: [TimelineStop(id, name, sfSymbolName?)],
    allowShuffle: Bool)` — the animation/timeline scrubber.

Runtime note (why the silence test was moot): the run added an appearance-toggle
probe, but the only text-addressable canvas control in this Xcode 26 layout is
the destination picker ("Automatic – My Mac" → My Mac / Mac Catalyst / More) —
the appearance/variants controls are icon buttons OCR cannot target. So the
attempted toggle was a no-op (canvas stayed light, Count unchanged;
`07c`/`07d`). It did not matter: the reply-carries-`controlDescriptions` design
proves the chrome is shell-rendered, so an NSEvent-silence observation would
have been redundant. Evidence + the full demangled export dump:
`research/scripts/data/254-s2-chrome/`.

Implication for #254 (confirms S4's hybrid): v1 needs this channel for any
device/appearance chrome. The agent emits `CanvasControlDescription`s in its
render reply; the shell renders them and returns `CanvasControlEvent`s. This is
orthogonal to the Option-B NSEvent path (live in-preview pointer/keyboard).

## S3 RESOLVED — selection is a shell-side hit-test, separate from live input

Verdict: a canvas selection is resolved by the shell hit-testing the click
against agent-produced regions, with NO round-trip to the agent. It is separate
from the S1 live-pointer path, and the two are chosen by canvas mode (live/play
forwards the NSEvent per S1; selectable/inspect consumes the click for a local
region hit-test). Settled by static RE (the `SelectableRegion` shape, already in
the S2 dump `research/scripts/data/254-s2-chrome/control-exports.txt`) plus the
S1 runtime result.

How `selectableRegions` are produced agent-side (the brief's open question):

- `SelectableRegion(path: String, rect: __C.CGRect, accessibilityElement:
  Foundation.Data?)`, plus `scaledBy(Double)` (zoom/HiDPI) and a `propertyListValue`
  codec. So each region is a hit `rect` (canvas coords), a `path` string (the
  view identity used for selection), and an optional archived AX element blob.
- The agent ships an array of these alongside every frame: `RenderPayload`,
  `IOSurfacePayload`, and the geometry-only `GeometryPayload` all expose
  `selectableRegions: [SelectableRegion]`. So selection data rides with the
  render reply, not a separate query.
- There is NO `hitTest`/`selectAt` request symbol from shell back to the agent
  (searched the exports). The shell owns the hit-test: it has `rect` + `path` +
  AX locally, so it resolves selection and drives the inspector without the
  agent. This is why selection is independent of (and cheaper than) the live
  event path.

Implication for #254: if our shell wants Xcode-style selection, the agent must
emit `selectableRegions` next to its IOSurface frame (one `{rect, path, AX?}`
per selectable view), and the shell hit-tests locally. #254 already plans an
IOSurface display path (`project_macos_agent_shell_derisk`), so this slots in as
an extra field on that frame payload. It is optional for a v1 that only needs
live interaction; it is required for click-to-select/inspect.

Not runtime-demoed (and why it is unnecessary): a clean demo would switch the
canvas to selectable mode and show a click highlighting the view without
incrementing the counter. The mode toggle is an icon button OCR cannot target
(same blocker as S2's chrome controls). But the type shapes are decisive: the
agent ships full hit-test data to the shell and there is no select-request back,
so selection is shell-side by construction. Residual unknown: the exact bytes of
the `accessibilityElement` archive (an `NSAccessibility`-element encoding) — not
needed for #254 unless we mirror Xcode's AX-driven selection.

## Constraints and gotchas (carry forward)

- Use the research VM for Xcode RE/dtrace; restore post-xcode-ready snapshot
  (`project_vm_capture_baseline`). Do RE after `AGENT_UP` + fd-redirect.
- These Xcode types confirm the PROTOCOL; we reimplement, never link against them.
- Prefer in-process / no-permission primitives. `CGEventPostToPid` is unreliable for
  off-screen/non-frontmost targets and needs Accessibility + non-sandboxed — treat as
  last resort, not a baseline.
- Two sims are often booted by parallel agents; the streaming agent uses sim
  92BCBA8E. Not relevant to macOS RE but avoid stepping on its VM/sim.
- Coordinate with the `previews-research` mailbox agent; this overlaps the
  `project_sim_streaming_architecture` IOSurface work.

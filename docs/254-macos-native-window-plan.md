# #254 macOS preview — native window with seamless respawn handoff

## Summary

The shipped #254 macOS path (shell-owns-agent) regressed the macOS
experience: it is not a true macOS view. The agent renders off-screen, rasters
its frame on the CPU (`cacheDisplay` → `CGImage` → IOSurface), and a separate
shell process hosts that raster cross-process via `CALayerHost`; input is
captured in the shell, shipped over a pipe, and replayed as synthesized
`NSEvent`s. The result is a fixed-size screenshot in a window — it does not
resize, scroll, or animate natively, input feels indirect, and it is not
performant. A spike proved the root cause is unfixable in that topology: a
`CAContext` carries **pixels, not views** — vending a live `NSHostingView`'s
backing layer hosts nothing (the consumer shows empty), while a plain `CALayer`
tree hosts fine. So any cross-process hosting is necessarily a raster.

This plan reverses that decision for macOS. Unlike Xcode — whose canvas is
embedded inside the Xcode app window and is therefore *forced* to host pixels
cross-process — our preview is a standalone OS window dedicated to one preview.
So the **agent can own that real window directly**: a real `NSWindow` with a
real `NSHostingView`, native input, native resize and scrolling, GPU
compositing, and no raster, no hosting, no input replay. The one hard problem is
that the JIT metadata leak forces an agent respawn on every structural edit (on
macOS as on iOS), and a respawn would close an agent-owned window. A second
spike proved the fix: a **seamless handoff** — the daemon spawns the new agent,
waits for its window to be up and rendered at the same frame, then kills the old
agent. Because the new window covers the same rectangle before the old one dies,
there is no visible gap. The wrong order (kill then spawn) shows the desktop;
the right order is seamless.

## Why the shipped approach is wrong (evidence)

Spike artifacts and findings: [`research/254-native-window-spike/`](../research/254-native-window-spike/).

- **Cross-process hosting is pixels, not views.** Vending an `NSHostingView`
  backing layer over a `CAContext` (`ctx.layer = hosting.layer`) hosts nothing —
  the consumer shows only its own fallback background — whether the producer
  window is off-screen or on-screen. A pure `CALayer` tree (background colors,
  render-server animation) hosts live and correctly. A view renders into its
  window's backing surface, not into a free-standing, re-hostable layer.
  Therefore the shipped path's raster is not an accident; *some* raster is
  mandatory for any cross-process hosting.
- **The raster we ship is slow and wrong-sized.** It is a CPU `cacheDisplay`,
  produced only on render/input events (with a ~30 ms run-loop spin per input),
  at the agent's fixed off-screen size. So it cannot reflow to the window
  (content pins to a corner), and interaction is janky.
- **The topology was copied from iOS, where it is forced and here it is not.**
  On iOS only a foreground app can host a scene, so the agent cannot own a
  visible window and a shell must. macOS has no such restriction: a process can
  own a visible `NSWindow`. We paid the iOS tax without the iOS reason.

## The macOS opportunity

Xcode must embed its canvas inside the Xcode window, so it cross-process hosts
the agent's pixels (its primary path is a `CAContext` layer fed by a rendered
surface, with an IOSurface secondary). We are not constrained that way: our
preview window is standalone and single-purpose. So we can let the agent own the
real window and get a genuinely native view — the thing Xcode cannot do because
its canvas is not a standalone window.

## Target topology

```
  daemon (long-lived, MainActor): MCP + orchestration
    │  compiles structural edits; coordinates respawn handoff; tracks the
    │  session's window frame; serves preview_snapshot
    │
    │  (no shell process — deleted)
    ▼
  agent (respawns per structural edit): owns ONE real visible NSWindow
    • NSHostingView renders the SwiftUI body into the real window
    • receives native NSEvents directly (no capture/replay)
    • resizes / scrolls / animates natively
    • on request, snapshots its own live window
    • on first render of a new generation, signals "ready" (window number + frame)
```

There is no persistent window-owner. Window continuity across respawn comes from
**overlapping two agent windows at the same frame**, not from a shell that
outlives the agent.

## The four crossings, reconsidered

1. **Display** — the agent owns a real on-screen `NSWindow` whose content view is
   the `NSHostingView`. The window *is* the preview. No `CAContext`, no
   `CALayerHost`, no IOSurface, no raster.
2. **Respawn** — daemon-coordinated handoff (next section). The new agent opens
   its window at the previous generation's current frame; frame and key-state are
   preserved.
3. **Input** — native. Real `NSEvent`s are delivered to the agent's real focused
   window by AppKit. No capture, no serialization, no synthesis, no run-loop
   spin, no re-raster.
4. **Snapshot** — the agent reads its own live window (`cacheDisplay` of the
   on-screen content view, or a window capture) on request and writes the PNG the
   daemon already tracks. `preview_snapshot` serves that.

## Respawn handoff protocol (the core new mechanism)

On a structural edit (which forces a fresh agent because of the JIT leak):

1. Daemon compiles the new object for generation N+1.
2. Daemon reads generation N's **current** window frame (the user may have moved
   or resized it) and whether it is key/frontmost.
3. Daemon spawns the gen N+1 agent, passing that frame.
4. Gen N+1 agent: create the `NSWindow` at the frame, install the
   `NSHostingView` with the new content, `orderFront` (and `makeKey`/activate
   only if gen N was key), render the first frame, then write a **ready signal**
   (window number + frame) over the existing render/sidecar handshake.
5. Daemon waits for the ready signal (with a timeout).
6. Daemon kills gen N. Its window closes; gen N+1 already covers the same
   rectangle in front, so there is no visible gap.
7. Daemon records gen N+1 as current and updates the tracked frame.

Ordering is the whole trick (proven by the spike): spawn-and-render **before**
kill is seamless; kill-before-spawn shows the desktop. Within a generation (no
structural edit — a literal edit or live interaction) the same agent and window
persist, so there is no handoff and interaction stays fully in-place.

### Edge cases

- **New agent fails to start or render:** do not kill gen N. The old preview
  stays on screen; surface the compile/run error. No gap, no data loss.
- **User moved/resized the window:** step 2 captures the live frame just before
  spawn, so placement persists across edits. This is what the old #195
  frame-restore logic was for; it is repurposed here instead of deleted.
- **Focus stealing:** activating the new window on every edit is disruptive.
  Only `makeKey`/activate when gen N was key/frontmost; otherwise `orderFront`
  at the same z-position. Preserve and carry the key-state across the handoff.
- **Ready-signal timing:** signal only *after* the render entry completes (content
  drawn), not when the window is merely created, or the overlap frame is blank.
- **Multi-session:** each session is its own agent + window; the daemon tracks N
  independent handoffs. Unchanged from today's per-session reloader model.
- **Headless (CI/snapshot):** no visible window; the agent renders off-screen and
  the daemon reads the snapshot. This path predates #254 and is unaffected.

## What to keep, drop, and add

**Drop** (the cross-process machinery):
- `PreviewShell` process and target; `ProcessPreviewShellController`;
  `PreviewShellController`/`NoopShellController` indirection.
- `RemoteContext` raster vend (`previewsmcp_vend_image`) and the `CAContext` /
  `CALayerHost` path.
- Input pipe + replay: `PreviewInputEvent`, the `dispatchPreviewInput` generated
  entry, `EventLineReader`, `PreviewHost.dispatchInput`,
  `StructuralReloader.dispatchInput`.
- IOSurface snapshot path and the `contextId` / `surfaceId` / `input` sidecars.

**Keep / restore:**
- Agent owns the visible `NSWindow` rendered by `NSHostingView` (pre-#254 shape).
- JIT structural-reload + respawn machinery (`JITStructuralReloader`,
  generation cap, per-session reloader).
- Frame preservation across respawn (old #195 logic), repurposed for the
  handoff.
- Literal-only reload in place; snapshot-from-window.

**Add:**
- Daemon-side respawn-handoff coordinator (spawn-new → await-ready → kill-old).
- Ready-signal handshake carrying window number + frame.
- Live-frame capture of the outgoing generation before spawn.

Net effect: this reverses the #254 display and input model for macOS and
replaces the #195 "restore the frame after the flash" hack with an overlap that
prevents the flash.

## Performance

A native window is GPU-composited live SwiftUI: native scrolling, resize, and
animation, and native event handling. We delete the per-event CPU raster, the
run-loop spin, the IOSurface copies, and the cross-process hosting overhead. The
only respawn is on a structural edit, which already pays a recompile; the handoff
hides even that. This should match or beat Xcode, which still pays for
cross-process pixel hosting that we no longer do.

## Phasing (each phase ships and verifies on its own)

### Phase A1 — agent owns the visible window again
Re-establish the on-screen `NSWindow` + `NSHostingView` render; remove the raster
vend and the `CALayerHost` hosting. Snapshot reads the live window.
- Verify: a visible native window appears; resizing the window reflows the
  SwiftUI content; scrolling a `List` works; `preview_snapshot` returns the live
  window; a manual run of the SPM `ToDoView` looks native and fills the window.

### Phase A2 — native input
Remove the capture/pipe/replay; real events reach the real window.
- Verify: click a button and the action runs; type into a `TextField`; scroll a
  list — all natively, no synthesized events, no re-raster.

### Phase A3 — respawn handoff coordinator
Implement spawn-new → await-ready → kill-old with frame and key-state preserved.
- Verify: force a structural edit on a stateful preview; the window stays put
  with no gap and no flicker (reproduce the spike's seamless transition end to
  end), and a moved/resized window keeps its placement across the edit.

### Phase A4 — cleanup + gates
Delete `PreviewShell`, `RemoteContext`, the sidecars, and the input pipe; run
`/simplify`, `/code-review`, and the full local suite.
- Verify: no dead references; macOS suites green; lint clean.

## Risks

- **Focus stealing on respawn** — mitigated by carrying key/frontmost state and
  only activating when warranted.
- **Two windows briefly in Cmd-Tab / Dock during overlap** — brief and minor;
  both are the agent executable.
- **Ready-signal correctness** — a too-early signal yields a blank overlap frame;
  signal after the first render completes.
- **Visible mode needs a live WindowServer/GUI session** — same constraint as
  today; headless rendering is unaffected.

## Already derisked (do not re-litigate)

- Cross-process `CAContext` hosting carries pixels, not views — an
  `NSHostingView` layer cannot be hosted live (spike).
- A native-window respawn handoff is seamless when the new window is up and
  front before the old is killed; the reverse order shows a desktop gap (spike).
- `NSRemoteView` / ViewBridge is a dead-end for a self-spawned agent (prior RE).

## Source-of-truth inputs

- Spike + findings: [`research/254-native-window-spike/`](../research/254-native-window-spike/).
- Superseded plan (shell-owns-agent): [`254-macos-shell-owns-agent-plan.md`](254-macos-shell-owns-agent-plan.md).
- Input forwarding research (still valid for iOS): the `previews-research`
  branch `research/254-macos-input-*.md`.
```

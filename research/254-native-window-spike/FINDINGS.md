# #254 native-window spike — findings

Two spikes that drove the macOS rethink in
[`docs/254-macos-native-window-plan.md`](../../docs/254-macos-native-window-plan.md).
Both are macOS GUI programs; run them in a logged-in Aqua session. Build with
`./build.sh`.

## Spike 1 — can a CAContext host a live SwiftUI view? (No.)

Question: the shipped #254 path rasters the agent frame and hosts the raster.
Could we instead host the agent's *live* `NSHostingView` layer over a `CAContext`
(like our `layerhost-spike` proved for a plain `CALayer`), and get a native,
self-updating preview?

Run:

```
./producer_live ./ctxid            # off-screen NSHostingView, vends ctx.layer = hosting.layer
ONSCREEN=1 ./producer_live ./ctxid # same, but on-screen window
./consumer ./ctxid                 # hosts the contextId via CALayerHost
```

Result: **the consumer is empty** (shows only its own fallback background),
off-screen *and* on-screen. By contrast `../layerhost-spike/producer` (a plain
`CALayer` tree) hosts live and correctly.

Conclusion: a `CAContext` carries **pixels, not views**. An `NSView` renders into
its window's backing surface, not into a free-standing, re-hostable layer. So any
cross-process hosting is necessarily a raster — there is no "host the live view"
shortcut. This is why the shipped raster path is not a fixable mistake but an
inherent property of the topology, and why macOS should drop cross-process
hosting and let the agent own the real window.

## Spike 2 — is a native-window respawn handoff seamless? (Yes, if ordered.)

Question: if the agent owns the real window, the JIT-leak-forced respawn on each
structural edit would close it. Can we hand off to a new agent with no visible
gap?

`agent_native` owns a real native SwiftUI window at a given frame:
`agent_native <label> <r> <g> <b> <x> <y> <w> <h>`.

Good order (spawn new at the same frame, order it front, render, THEN kill old):

```
./agent_native "OLD v1" 0.85 0.2 0.2  400 300 460 340   # gen 1, red
# ... read its frame with ./wbounds agent_native ...
./agent_native "NEW v2" 0.2 0.75 0.3  400 300 460 340   # gen 2, green, same frame, front
kill <old pid>                                           # only after gen 2 is up + rendered
```

Result: **seamless** — the region shows red → green → green with no gap and no
movement (`h_t0`/`h_t1`/`h_t2` in the plan). The reverse order (kill old, then
spawn new) shows the **desktop** in the gap (`bad_gap`). Ordering is the whole
trick: the new window must cover the same rectangle before the old one dies.

Conclusion: Option A (agent owns the real window) is viable. The daemon must
spawn the new agent, wait for a "first frame rendered" signal at the same frame,
then kill the old agent. See the plan's handoff protocol.

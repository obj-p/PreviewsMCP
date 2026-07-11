# #254 layer-hosting spike

A two-process proof of the macOS cross-process display primitive behind #254.
The **producer** stands in for the preview agent; the **consumer** stands in for
the shell. Reconstructed from `project_macos_agent_shell_derisk` after the
original `/tmp` copy was lost (it was never committed).

## What it proves

1. **Cross-process layer hosting works** for a self-spawned process pair on
   macOS, with no `.appex`/NSExtension: the consumer's `NSWindow` shows the
   producer's live, animating layer by binding `CALayerHost.contextId` to the
   producer's `CAContext.contextId`. No `NSRemoteView`/ViewBridge.
2. **The WindowServer holds the last frame when the producer dies** — the
   consumer window keeps showing the frozen content instead of going blank. This
   is the never-blank-across-respawn behavior for free.
3. **Re-host on respawn** — relaunch the producer (new `contextId`); the consumer
   polls the id file and rebinds `CALayerHost.contextId`, so the same window
   shows the new producer's content and never closes.

## Mechanism

- `+[CAContext remoteContextWithOptions:]` → `CAContext` with a settable `.layer`
  and a read-only `.contextId` (UInt32). Private QuartzCore SPI.
- `CALayerHost` (CALayer subclass) with a settable `contextId`. Set it to the
  producer's `contextId` to host that layer.
- The public wrapper `CARemoteLayerServer`/`Client` is reportedly broken on
  modern macOS, so this uses the private `CAContext`/`CALayerHost` directly —
  the same path Xcode uses (`MacOSLayerHostedPreviewViewable(contextID:)`).

## Build & run

```
./build.sh
./producer ./ctxid &        # writes its contextId to ./ctxid, animates
./consumer ./ctxid &        # opens a window, binds the contextId, prints windowNumber
# capture the consumer window (windowNumber is on the consumer's stderr):
screencapture -l<WINDOW_NUMBER> out-window.png
kill %1                     # kill the producer -> consumer holds the last frame
./producer ./ctxid &        # respawn -> consumer rebinds, window never closed
```

Needs a live WindowServer/CA session (a logged-in GUI session), not a detached
daemon. Snapshots in the product use an IOSurface read, not `screencapture`.

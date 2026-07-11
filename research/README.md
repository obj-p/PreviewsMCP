# research/

Non-shipping reference material: exploratory spikes and research briefs that
back product decisions. Nothing here is built by Bazel or `Package.swift`, and
`research/` is excluded from the lint sweep (`tools/lint/lint.sh`), same bucket
as `examples/`. Compiled spike binaries are never committed — build them from
source with each spike's `build.sh` in a logged-in GUI session.

## #254 macOS native-window preview

The design that reverses the shipped shell-owns-agent macOS path to
agent-owns-a-real-`NSWindow` with a seamless respawn handoff. Plan doc:
[`docs/254-macos-native-window-plan.md`](../docs/254-macos-native-window-plan.md).

| Path | What it is |
|---|---|
| [`layerhost-spike/`](layerhost-spike/) | Two-process proof of the cross-process display primitive: `CAContext` → `CALayerHost` hosts a live layer, holds the last frame when the producer dies, and re-hosts on respawn. Shows a `CAContext` carries pixels, not views. |
| [`254-native-window-spike/`](254-native-window-spike/) | Two spikes behind the rethink: (1) a `CAContext` cannot host a live `NSHostingView` (so any cross-process hosting is a raster), and (2) the ordered respawn handoff is gapless — spawn+render the new window before killing the old. See `FINDINGS.md`. |
| [`254-macos-input-plan.md`](254-macos-input-plan.md) | Implementation plan for macOS input: native `NSEvent`s into one real window for live interaction, separate semantic channels for chrome/selection. |
| [`254-macos-input-forwarding.md`](254-macos-input-forwarding.md) | Research brief on cross-process input forwarding for the (now reversed) shell-owns-agent topology. |

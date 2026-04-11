---
name: previewsmcp
description: Render SwiftUI previews outside Xcode with hot-reload, trait variants, and touch interaction. Use when an agent needs to see or interact with a `#Preview` without building the full app.
---

# previewsmcp

Render SwiftUI `#Preview` blocks headlessly on macOS or iOS simulator. Hot-reload, trait overrides, accessibility tree, touch injection, variant snapshots.

## Tools

<!-- eval:tools -->
preview_list, preview_start, preview_configure, preview_switch, preview_variants, preview_snapshot, preview_elements, preview_touch, preview_stop, simulator_list

## When to use which tool

**Just looking at a preview:** `preview_start` → `preview_snapshot` → `preview_stop`. Pass `platform: "ios"` only if the preview uses iOS-only APIs or you need touch interaction.

**Iterating on design:** Keep one session alive. Edit the source file — hot-reload picks it up. Call `preview_snapshot` after each change. Don't tear down between edits.

**Multiple `#Preview` blocks in one file:** `preview_list` first to see them all, then `preview_start` with `previewIndex`, then `preview_switch` to change which one renders without restarting the session. Traits persist across switches; `@State` resets.

**Checking light/dark or Dynamic Type:** For a one-off, `preview_configure` on a live session. For a batch (light + dark + a11y sizes in one shot), `preview_variants` — it renders each, snapshots it, and restores the original traits. `preview_variants` is cheaper than repeated `preview_configure` calls because the session stays up.

**Interacting with iOS previews:** `preview_elements` to get the accessibility tree (filter by `"interactable"` to narrow), then `preview_touch` with the element's frame center. Don't guess coordinates from a screenshot — ask the tree.

## Trait presets

<!-- eval:presets -->
light, dark, xSmall, small, medium, large, xLarge, xxLarge, xxxLarge, accessibility1, accessibility2, accessibility3, accessibility4, accessibility5

Pass these names directly to `preview_variants`. For custom combinations, pass a JSON object string: `{"colorScheme":"dark","dynamicTypeSize":"accessibility3","label":"dark+a11y3"}`.

## Gotchas

- `dynamicTypeSize` has no visible effect on macOS. Use `platform: "ios"` to test Dynamic Type.
- Every `preview_configure`, `preview_switch`, and each variant in `preview_variants` triggers a recompile. `@State` is lost on each.
- `preview_elements` and `preview_touch` are iOS-only.
- Always call `preview_stop` when done — live sessions hold simulator resources.

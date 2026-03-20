# Bazel Example Project

A minimal SwiftUI library built with Bazel, with a cross-file type dependency, used to integration test PreviewsMCP's Bazel build system support.

## Structure

```
Sources/ToDo/
├── BUILD.bazel    — swift_library target
├── Item.swift     — defines Item model (used by views)
└── ToDoView.swift — view + #Preview that references Item
```

The `#Preview` in `ToDoView.swift` uses `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the Bazel project, build it, and compile the preview against the target's build artifacts.

The UI includes tappable item rows (toggle completion), a toggle switch, and a horizontally paged summary card section — suitable for testing tap, toggle, and swipe interactions.

## Prerequisites

Install bazelisk (manages Bazel versions via `.bazelversion`):

```bash
# Option A: mise (reads .mise.toml)
mise install

# Option B: Homebrew
brew install bazelisk
```

## Build

```bash
cd examples/bazel
bazel build //Sources/ToDo
```

Build outputs land in `bazel-bin/Sources/ToDo/` — the `.swiftmodule` and object files that PreviewsMCP needs for Tier 1 (bridge-only) compilation.

## Integration Test Prompt

Use this prompt to test PreviewsMCP's Bazel integration end-to-end:

```
Run the following integration test for PreviewsMCP's Bazel build system support.
The example project is at examples/bazel/ relative to the PreviewsMCP repo root.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root
- Build the Bazel example: `cd examples/bazel && bazel build //Sources/ToDo`

### 2. Basic rendering (macOS)
- Use preview_start on examples/bazel/Sources/ToDo/ToDoView.swift
- Take a snapshot — verify it shows "My Items" nav title with a summary card section and 8 item rows
- The first item ("Design UI") should have a filled checkmark; others should have empty circles
- The first summary card (blue "Progress") should show "1/8" with "7 remaining"

### 3. Interaction (iOS simulator)
- Use preview_start with platform "ios-simulator" on the same file
- Use preview_elements to get element frames for accurate tap coordinates
- Tap an uncompleted item (e.g. "Write code") — verify its checkmark changes to filled
- Tap the "Show Completed" toggle — verify completed items are hidden
- Swipe the summary cards left (horizontal swipe) — take a snapshot and verify the orange "Next Up" card is now visible instead of the blue "Progress" card

### 4. Cross-file edit
- With a preview session running, add a new item to Item.samples in Item.swift
- Rebuild: `cd examples/bazel && bazel build //Sources/ToDo`
- Take a snapshot — verify the new item appears (Tier 1: requires rebuild, no automatic hot-reload)
- Revert the change

### 5. Cleanup
- Stop all preview sessions
```

### Differences from SPM

| Aspect | SPM | Bazel |
|--------|-----|-------|
| Compilation tier | Tier 2 (source compilation) | Tier 1 (bridge-only) |
| Hot-reload | Literal + cross-file (automatic) | Requires manual `bazel build` |
| Detection marker | `Package.swift` | `BUILD.bazel` / `WORKSPACE` / `MODULE.bazel` |
| Artifact location | `.build/<triple>/debug/Modules/` | `bazel-bin/Sources/ToDo/` |

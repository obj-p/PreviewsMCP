# Bazel Example Project

A minimal SwiftUI library built with Bazel, with a cross-file type dependency, used to integration test PreviewsMCP's Bazel build system support.

## Structure

```
Sources/ToDo/
├── BUILD.bazel                — swift_library target
├── Item.swift                 — defines Item model (used by views)
├── ToDoView.swift             — view + #Preview that references Item
└── ToDoProviderPreview.swift  — PreviewProvider-based preview for integration testing
```

The `#Preview` blocks in `ToDoView.swift` use `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the Bazel project, build it, and compile the preview against the target's build artifacts. The file has two previews: the default (with sample data) and "Empty State" (no items).

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

Build outputs land in `bazel-bin/Sources/ToDo/` — the `.swiftmodule` and object files that PreviewsMCP uses. PreviewsMCP also queries source files via `bazel query` for Tier 2 (source compilation with hot-reload).

## Integration Test Prompt

Use this prompt to test PreviewsMCP's Bazel integration end-to-end:

```
Run the following integration test for PreviewsMCP's Bazel build system support.
The example project is at examples/bazel/ relative to the PreviewsMCP repo root.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root
- Trust mise configs (worktrees): If running in a git worktree, the Bazel example's `.mise.toml` has a different absolute path than in the main repo, so mise will refuse to load it. Run `mise trust examples/bazel/.mise.toml` before testing the Bazel example to ensure the `bazel` shim works.

### 2. Basic rendering (macOS)
- Use preview_start on examples/bazel/Sources/ToDo/ToDoView.swift with projectPath set to examples/bazel/ (required — without it, auto-detection finds the repo root Package.swift and fails)
- Take a snapshot — verify it shows "My Items" nav title with a summary card section and 8 item rows
- The first item ("Design UI") should have a filled checkmark; others should have empty circles
- The first summary card (blue "Progress") should show "1/8" with "7 remaining"
- Stop the macOS session before moving on

### 3. Interaction (iOS simulator)
- Use preview_start with platform "ios" on the same file (keep projectPath set to examples/bazel/)
- Use preview_elements to get element frames for accurate tap coordinates
- Tap an uncompleted item (e.g. "Write code") — verify its checkmark changes to filled
- Tap the "Show Completed" toggle — verify completed items are hidden
- Swipe the summary cards left (horizontal swipe) — use the TabView/page control frame from preview_elements to find the card section's vertical bounds, and swipe within that area (not in the list below it). Take a snapshot and verify the orange "Next Up" card is now visible instead of the blue "Progress" card

### 4. Hot reload — literal edit
- With a preview session running, change "My Items" to "Tasks" in ToDoView.swift (the navigationTitle string)
- Take a snapshot — verify the title now shows "Tasks"
- Revert the change

### 5. Hot reload — cross-file edit
- With a preview session running, add a new item to Item.samples in Item.swift
- Take a snapshot — verify the new item appears (file watcher monitors all target files)
- Revert the change

### 6. Multi-preview and switching
- Call preview_list — verify two previews with snippets
- Call preview_switch with previewIndex 1 — take a snapshot and verify the empty state (no item rows)
- Call preview_switch with previewIndex 0 — verify the full item list returns

### 7. PreviewProvider support
- Call preview_list on ToDoProviderPreview.swift (keep projectPath set to examples/bazel/) — verify two previews: `[0] Default` and `[1] Empty State`
- Use preview_start on ToDoProviderPreview.swift — take a snapshot and verify it shows the full item list
- Call preview_switch with previewIndex 1 — take a snapshot and verify the empty state
- Stop the session

### 8. Cleanup
- Stop all preview sessions
```

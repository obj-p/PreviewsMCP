# Bazel Example Project

SwiftUI targets built with Bazel, used to integration test PreviewsMCP's Bazel build system support. It covers a plain `swift_library` (ToDo) plus the Apple bundle target types — an `ios_application` and an `ios_framework` — each with cross-module dependencies.

## Structure

```
Sources/
├── ToDo/                       — swift_library
│   ├── BUILD.bazel
│   ├── Item.swift              — defines Item model (used by views)
│   ├── ToDoView.swift          — view + #Preview that references Item
│   └── ToDoProviderPreview.swift — PreviewProvider-based preview
├── ObjCLib/                    — objc_library (PSGreeting.message())
├── SwiftLib/                   — swift_library, depends on ObjCLib (GreetingBadge)
├── App/                        — ios_application + its swift_library
│   ├── BUILD.bazel             — MixedApp (ios_application) → MixedApp.library
│   ├── MixedApp.swift          — @main App entry point
│   └── ContentView.swift       — #Preview, imports ObjCLib + SwiftLib
└── PreviewKit/                 — ios_framework + its swift_library
    ├── BUILD.bazel             — PreviewKit (ios_framework) → PreviewKit.library
    └── PreviewView.swift       — #Preview
```

### ToDo (swift_library)

The `#Preview` blocks in `ToDoView.swift` use `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the Bazel project, build it, and compile the preview against the target's build artifacts. The file has two previews: the default (with sample data) and "Empty State" (no items).

The UI includes tappable item rows (toggle completion), a toggle switch, and a horizontally paged summary card section — suitable for testing tap, toggle, and swipe interactions.

### Apple bundle targets and multiple targets

`ContentView.swift` (the app) and `PreviewView.swift` (the framework) each render through the bundle's underlying `swift_library`, not the `ios_application` / `ios_framework` rule itself. PreviewsMCP resolves a preview by source **file**: it finds the nearest `BUILD`, then queries `kind("swift_library", rdeps(//<pkg>:all, //<pkg>:<File>.swift))` to find the `swift_library` in that package that owns the file. So multiple targets in different packages each route to their own library.

These two files exercise the parts of the Bazel support that a plain `swift_library` does not:

- **Cross-module dependencies.** `ContentView` imports the `objc_library` `ObjCLib` and the `swift_library` `SwiftLib`. PreviewsMCP pulls the dependency module search paths from the target's compile action and builds + links the dependency archives into the preview.
- **`@main` app target.** `MixedApp.swift` carries the `@main` entry point. It is excluded from the preview compile (its app-lifecycle entry symbol would break the preview JIT link); the preview renders `ContentView()` on its own.
- **iOS SDK transition.** On `--platform ios` the targets and their dependencies build through the real iOS-simulator platform transition.

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

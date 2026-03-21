# Xcode Workspace Example Project

A minimal SwiftUI framework built with an Xcode workspace (via XcodeGen), with a cross-file type dependency, used to integration test PreviewsMCP's `.xcworkspace` build system support.

## Structure

```
Sources/ToDo/
├── Item.swift      — defines Item model (used by views)
└── ToDoView.swift  — view + #Preview that references Item
project.yml         — XcodeGen spec (generates ToDo.xcodeproj)
ToDo.xcworkspace/   — workspace wrapping ToDo.xcodeproj (committed)
```

The `#Preview` in `ToDoView.swift` uses `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the Xcode workspace, build it, and compile the preview against the target's build artifacts.

The key difference from the `xcodeproj` example: PreviewsMCP must detect the `.xcworkspace` and use `-workspace` instead of `-project` in xcodebuild commands.

## Prerequisites

Install [Mint](https://github.com/yonaskolb/Mint) and XcodeGen:

```bash
brew install mint
mint bootstrap   # installs XcodeGen from Mintfile
```

## Setup

```bash
cd examples/xcworkspace
mint run xcodegen generate
```

This creates `ToDo.xcodeproj` (git-ignored). The workspace references it. Regenerate after changing `project.yml` or adding/removing source files.

## Build

```bash
# macOS
xcodebuild build -workspace ToDo.xcworkspace -scheme ToDo -destination 'platform=macOS'

# iOS simulator
xcodebuild build -workspace ToDo.xcworkspace -scheme ToDo -destination 'platform=iOS Simulator,name=iPhone 16'
```

Build outputs land in DerivedData — the `.swiftmodule` and object files that PreviewsMCP needs for preview compilation.

## Integration Test Prompt

Use this prompt to test PreviewsMCP's Xcode workspace integration end-to-end:

```
Run the following integration test for PreviewsMCP's Xcode workspace support.
The example project is at examples/xcworkspace/ relative to the PreviewsMCP repo root.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root
- Generate the Xcode project: `cd examples/xcworkspace && mint run xcodegen generate`
- Build via workspace: `xcodebuild build -workspace ToDo.xcworkspace -scheme ToDo -destination 'platform=macOS'`

### 2. Basic rendering (macOS)
- Use preview_start on examples/xcworkspace/Sources/ToDo/ToDoView.swift with projectPath set to examples/xcworkspace/ (required — without it, auto-detection finds the repo root Package.swift and fails)
- Take a snapshot — verify it shows "My Items" nav title with a summary card section and 8 item rows
- The first item ("Design UI") should have a filled checkmark; others should have empty circles
- The first summary card (blue "Progress") should show "1/8" with "7 remaining"

### 3. Interaction (iOS simulator)
- Use preview_start with platform "ios-simulator" on the same file (keep projectPath set to examples/xcworkspace/)
- Use preview_elements to get element frames for accurate tap coordinates
- Tap an uncompleted item (e.g. "Write code") — verify its checkmark changes to filled
- Tap the "Show Completed" toggle — verify completed items are hidden
- Swipe the summary cards left (horizontal swipe) — take a snapshot and verify the orange "Next Up" card is now visible instead of the blue "Progress" card

### 4. Hot reload — literal edit
- With a preview session running, change "My Items" to "Tasks" in ToDoView.swift (the navigationTitle string)
- Take a snapshot — verify the title now shows "Tasks"
- Revert the change

### 5. Hot reload — cross-file edit
- With a preview session running, add a new item to Item.samples in Item.swift
- Take a snapshot — verify the new item appears (file watcher monitors all target files)
- Revert the change

### 6. Cleanup
- Stop all preview sessions
```

## Differences from Other Examples

| Aspect | SPM | Xcode (.xcodeproj) | Xcode (.xcworkspace) | Bazel |
|--------|-----|---------------------|----------------------|-------|
| Compilation tier | Tier 2 (source compilation) | Tier 2 (source compilation, Tier 1 fallback) | Tier 2 (source compilation, Tier 1 fallback) | Tier 2 (source compilation) |
| Hot-reload | Literal + cross-file (automatic) | Literal + cross-file (automatic) | Literal + cross-file (automatic) | Literal + cross-file (automatic) |
| Detection marker | `Package.swift` | `.xcodeproj` | `.xcworkspace` | `BUILD.bazel` / `MODULE.bazel` |
| xcodebuild flag | N/A | `-project` | `-workspace` | N/A |
| Artifact location | `.build/<triple>/debug/Modules/` | DerivedData | DerivedData | `bazel-bin/Sources/ToDo/` |
| Project generator | N/A | XcodeGen (`project.yml`) | XcodeGen (`project.yml`) | N/A |

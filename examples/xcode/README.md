# Xcode Example Project

A minimal SwiftUI framework built with Xcode (via XcodeGen), with a cross-file type dependency, used to integration test PreviewsMCP's Xcode build system support.

## Structure

```
Sources/ToDo/
├── Item.swift      — defines Item model (used by views)
└── ToDoView.swift  — view + #Preview that references Item
project.yml         — XcodeGen spec (generates ToDo.xcodeproj)
```

The `#Preview` in `ToDoView.swift` uses `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the Xcode project, build it, and compile the preview against the target's build artifacts.

The UI includes tappable item rows (toggle completion), a toggle switch, and a horizontally paged summary card section — suitable for testing tap, toggle, and swipe interactions.

## Prerequisites

Install [Mint](https://github.com/yonaskolb/Mint) and XcodeGen:

```bash
brew install mint
mint bootstrap   # installs XcodeGen from Mintfile
```

## Setup

```bash
cd examples/xcode
xcodegen generate
```

This creates `ToDo.xcodeproj` (git-ignored). Regenerate after changing `project.yml` or adding/removing source files.

## Build

```bash
# macOS
xcodebuild build -project ToDo.xcodeproj -scheme ToDo -destination 'platform=macOS'

# iOS simulator
xcodebuild build -project ToDo.xcodeproj -scheme ToDo -destination 'platform=iOS Simulator,name=iPhone 16'
```

Build outputs land in DerivedData — the `.swiftmodule` and object files that PreviewsMCP needs for preview compilation.

## Integration Test Prompt

Use this prompt to test PreviewsMCP's Xcode integration end-to-end:

```
Run the following integration test for PreviewsMCP's Xcode build system support.
The example project is at examples/xcode/ relative to the PreviewsMCP repo root.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root
- Generate the Xcode project: `cd examples/xcode && xcodegen generate`
- Build the Xcode project: `xcodebuild build -project ToDo.xcodeproj -scheme ToDo -destination 'platform=macOS'`

### 2. Basic rendering (macOS)
- Use preview_start on examples/xcode/Sources/ToDo/ToDoView.swift
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
- With a preview session running, edit Item.swift (add a new item to Item.samples)
- Take a snapshot — verify the new item appears
- Revert the change

### 5. Cleanup
- Stop all preview sessions
```

## Differences from Other Examples

| Aspect | SPM | Xcode | Bazel |
|--------|-----|-------|-------|
| Compilation tier | Tier 2 (source compilation) | TBD (Tier 1 or 2) | Tier 1 (bridge-only) |
| Hot-reload | Literal + cross-file (automatic) | TBD | Requires manual `bazel build` |
| Detection marker | `Package.swift` | `.xcodeproj` | `BUILD.bazel` / `MODULE.bazel` |
| Artifact location | `.build/<triple>/debug/Modules/` | `DerivedData/.../<Target>.swiftmodule` | `bazel-bin/Sources/ToDo/` |
| Project generator | N/A | XcodeGen (`project.yml`) | N/A |

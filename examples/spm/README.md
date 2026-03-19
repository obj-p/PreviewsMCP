# SPM Example Project

A minimal SwiftUI library with a cross-file type dependency, used to integration test PreviewsMCP's SPM build system support. Targets both macOS and iOS.

## Structure

```
Sources/ToDo/
├── Item.swift      — defines Item model (used by views)
└── ToDoView.swift  — view + #Preview that references Item
```

The `#Preview` in `ToDoView.swift` uses `Item.samples` which is defined in `Item.swift`. This requires PreviewsMCP to detect the SPM package, build it, and compile the preview against the target's build artifacts.

The UI includes tappable item rows (toggle completion), a toggle switch, and a scrollable list — suitable for testing both tap and swipe interactions.

## Integration Test Prompt

Use this prompt to test PreviewsMCP's SPM integration end-to-end:

```
Run the following integration test for PreviewsMCP's SPM build system support.
The example project is at examples/spm/ relative to the PreviewsMCP repo root.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root

### 2. Basic rendering (macOS)
- Use preview_start on examples/spm/Sources/ToDo/ToDoView.swift
- Take a snapshot — verify it shows "My Items" nav title with 8 item rows
- The first item ("Design UI") should have a filled checkmark; others should have empty circles

### 3. Interaction (iOS simulator)
- Use preview_start with platform "ios-simulator" on the same file
- Use preview_elements to find the item rows and toggle
- Tap an uncompleted item (e.g. "Write code") — verify its checkmark changes to filled
- Tap the "Show Completed" toggle — verify completed items are hidden
- Swipe the list to scroll down and verify more items are visible

### 4. Hot reload — literal edit
- With a preview session running, change "My Items" to "Tasks" in ToDoView.swift (the navigationTitle string)
- Take a snapshot — verify the title now shows "Tasks"
- Revert the change

### 5. Hot reload — structural edit
- With a preview session running, add a new item to Item.samples in Item.swift
- Touch ToDoView.swift to trigger rebuild (file watcher monitors only the preview file)
- Take a snapshot — verify the new item appears in the list
- Revert the changes

### 6. Cleanup
- Stop all preview sessions
```

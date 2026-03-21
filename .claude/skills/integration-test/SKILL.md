---
name: integration-test
description: Run integration tests against example projects in the examples/ directory. Use when the user wants to validate PreviewsMCP's build system support, rendering, interaction, or hot-reload end-to-end.
argument-hint: [example-name]
allowed-tools: Bash, Read, Glob, Grep, preview_start, preview_snapshot, preview_elements, preview_touch, preview_stop, preview_list, simulator_list
---

Run integration tests for PreviewsMCP example projects.

## Arguments

- `$ARGUMENTS` — optional example name (e.g., `spm`, `playground`). If omitted, run all examples plus the playground test.

## Steps

1. **Discover examples.** List directories under `examples/` in the repo root. If `$ARGUMENTS` is provided and is not `playground`, filter to that example only. If the specified example doesn't exist, report the error and list available examples.

2. **Build PreviewsMCP.** Run `swift build` from the repo root. If the build fails, stop and report the error.

3. **For each example**, read its `README.md` and follow the "Integration Test Prompt" section. The README contains the exact steps to execute, including which MCP tools to call and what to verify.

4. **Run the playground test** (if `$ARGUMENTS` is `playground` or omitted). See the "Playground test" section below.

5. **Report results.** For each example, report pass/fail per test step. Summarize at the end.

## Project path guidance

The example projects are nested inside the PreviewsMCP repo, which has its own `Package.swift`. Without an explicit `projectPath`, auto-detection walks up from the source file, finds the repo root SPM package first, and fails. **Always pass `projectPath` pointing to the example directory** (e.g., `examples/bazel/` or `examples/xcodeproj/`) when calling `preview_start` for Bazel or Xcode examples. The SPM example does not need this because its `Package.swift` is the closest one found. The playground test uses standalone mode (no `projectPath`, no build system) — files live at `~/.previewsmcp/playground/`, outside any project tree.

## Trust mise configs (worktrees)

If running in a git worktree, the Bazel example's `.mise.toml` has a different absolute path than in the main repo, so mise will refuse to load it. Run `mise trust examples/bazel/.mise.toml` before testing the Bazel example to ensure the `bazel` shim works.

## Touch interaction guidance

When using `preview_touch` based on `preview_elements` frames:

- **SwiftUI Toggles** only respond to taps on the switch control itself (rightmost ~44pt of the row), not the label. When tapping a Toggle, use the right edge of the reported frame (e.g., `x = frame.x + frame.width - 20`) rather than the center.
- **Buttons and list rows** are tappable anywhere within their reported frame — center coordinates work fine.

## Hot reload timing

After editing a source file to test hot reload, wait **1 second** (`sleep 1`) before taking a snapshot. This is enough for the file watcher to detect the change and for literal-only reloads. For structural changes that trigger recompilation, wait **3 seconds**.

## Log sanity check

PreviewsMCP logs reload activity to stderr. After running all test steps, check the MCP server logs for errors:

```bash
# If the MCP server is running via `swift run previewsmcp serve`, its stderr
# contains lines like:
#   MCP: iOS file change detected, reloading session <id>...
#   MCP: iOS literal-only change applied (state preserved)
#   MCP: iOS structural change — recompiled and signalled reload
#   MCP: iOS reload failed for session <id>: <error>
#
# Grep the process stderr or system log for "MCP:" to verify no reload failures.
```

If any "reload failed" lines appear, report them as a test failure with the full error message.

## Playground test

When `$ARGUMENTS` is `playground` (or when running all tests), run this standalone preview test. Playground files live at `~/.previewsmcp/playground/` — outside any project tree to avoid build system detection.

### 1. Setup
- Build previewsmcp: `swift build` from the PreviewsMCP root
- Create the playground directory: `mkdir -p ~/.previewsmcp/playground`

### 2. Standalone rendering (macOS)
- Create `~/.previewsmcp/playground/IntegrationTest.swift` with:
  ```swift
  import SwiftUI

  struct IntegrationTestView: View {
      var body: some View {
          Text("Playground Test")
      }
  }

  #Preview {
      IntegrationTestView()
  }
  ```
- Use `preview_start` on the file (no `projectPath` — standalone mode)
- Take a snapshot — verify it renders "Playground Test"

### 3. Hot reload — literal edit
- Change `"Playground Test"` to `"Updated Text"` in the file
- Wait 1 second, take a snapshot — verify the text updated

### 4. Hot reload — structural edit
- Add a second `Text("Second line")` below the first (wrap in VStack if needed)
- Wait 3 seconds, take a snapshot — verify both texts appear

### 5. Cleanup
- Stop the preview session
- Delete `~/.previewsmcp/playground/IntegrationTest.swift`

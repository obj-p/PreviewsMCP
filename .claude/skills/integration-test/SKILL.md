---
name: integration-test
description: Run integration tests against example projects in the examples/ directory. Use when the user wants to validate PreviewsMCP's build system support, rendering, interaction, or hot-reload end-to-end.
argument-hint: [example-name]
allowed-tools: Bash, Read, Glob, Grep, preview_start, preview_snapshot, preview_elements, preview_touch, preview_stop, preview_list, preview_playground, simulator_list
---

Run integration tests for PreviewsMCP example projects.

## Arguments

- `$ARGUMENTS` — optional example name (e.g., `spm`). If omitted, run all examples.

## Steps

1. **Discover examples.** List directories under `examples/` in the repo root. If `$ARGUMENTS` is provided, filter to that example only. If the specified example doesn't exist, report the error and list available examples.

2. **Build PreviewsMCP.** Run `swift build` from the repo root. If the build fails, stop and report the error.

3. **For each example**, read its `README.md` and follow the "Integration Test Prompt" section. The README contains the exact steps to execute, including which MCP tools to call and what to verify.

4. **Test playground.** After example tests, run the playground integration test:
   - Call `preview_playground` with no arguments (default code) — verify it returns a session ID and file path
   - Take a snapshot — verify it renders the default "Hello, playground!" view
   - Call `preview_playground` with custom `code` containing a simple SwiftUI view — verify it compiles and renders
   - Take a snapshot of the custom code session — verify the custom view appears
   - Stop both playground sessions

5. **Report results.** For each example, report pass/fail per test step. Summarize at the end.

## Project path guidance

The example projects are nested inside the PreviewsMCP repo, which has its own `Package.swift`. Without an explicit `projectPath`, auto-detection walks up from the source file, finds the repo root SPM package first, and fails. **Always pass `projectPath` pointing to the example directory** (e.g., `examples/bazel/` or `examples/xcodeproj/`) when calling `preview_start` for Bazel or Xcode examples. The SPM example does not need this because its `Package.swift` is the closest one found.

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

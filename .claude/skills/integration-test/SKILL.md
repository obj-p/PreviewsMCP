---
name: integration-test
description: Run integration tests against example projects in the examples/ directory. Use when the user wants to validate PreviewsMCP's build system support, rendering, interaction, or hot-reload end-to-end.
argument-hint: [example-name]
allowed-tools: Bash, Read, Glob, Grep, preview_start, preview_snapshot, preview_configure, preview_switch, preview_elements, preview_touch, preview_stop, preview_list, preview_build_info, simulator_list
---

Run integration tests for PreviewsMCP example projects.

## Arguments

- `$ARGUMENTS` — optional example name (e.g., `spm`). If omitted, run all examples.

## Important: two server processes

PreviewsMCP runs as two separate processes with independent state:
- **Stdio MCP server** — spawned by Claude Code at session start via `.mcp.json`. This is what `mcp__previewsmcp__*` tool calls reach.
- **UDS daemon** — auto-spawned by every `previewsmcp` CLI subcommand. Persists across CLI invocations.

`swift build` overwrites the on-disk binary, but **resident processes keep running the old code** until they restart. Without an explicit check this skill could exercise a stale binary and report green against unchanged code. Steps 0 and 2 below guard against that.

## Steps

0. **Reset daemon state.** Run `previewsmcp kill-daemon`, then `previewsmcp status`. If `status` exits 0 (a daemon is still alive), abort the skill — a residual UDS daemon is potentially stale and is load-bearing for Step 7's `preview_list` calls on non-SPM examples.

1. **Discover examples.** List directories under `examples/` in the repo root. If `$ARGUMENTS` is provided, filter to that example only. If the specified example doesn't exist, report the error and list available examples.

2. **Build PreviewsMCP and verify the stdio server is fresh.** Run `swift build` from the repo root. If the build fails, stop and report the error. Then call `preview_build_info` (MCP tool). If the response has `stale: true`, abort with this message:

   > Stdio MCP server's on-disk binary was rebuilt at `<binaryMtime>` but the running process started at `<processStartTime>`. Type `/exit` and relaunch Claude Code so it respawns the MCP server from the new binary, then re-run this skill.

   If `stale: false`, proceed.

3. **For each example**, read its `README.md` and follow the "Integration Test Prompt" section. The README contains the exact steps to execute, including which MCP tools to call and what to verify.

4. **Test multi-preview and preview switching.** After example tests, test `preview_list` snippets, `preview_start` available-previews output, and `preview_switch` using the SPM example (which has two previews: `[0]` the default with sample data, `[1]` "Empty State" with no items).
   - Call `preview_list` on `examples/spm/Sources/ToDo/ToDoView.swift` — verify it shows two previews with closure body snippets (e.g., `[0] Preview (line …): ToDoView(items: Item.samples)` and `[1] Empty State (line …): ToDoView(items: [])`)
   - Start a macOS session on the same file (default `previewIndex: 0`) — verify the response includes an "Available previews" section listing both previews, an `<- active` marker on preview 0, and a `preview_switch` hint
   - Take a snapshot — verify it shows the full item list ("My Items", 8 rows)
   - Call `preview_switch` with `previewIndex: 1` — verify success
   - Take a snapshot — verify it now shows the empty state (no item rows, just the nav title)
   - Call `preview_switch` with an invalid `previewIndex` (e.g., `99`) — verify it returns an error and the session remains on preview 1 (rollback)
   - Take a snapshot after the failed switch — verify the empty state is still rendered (confirming rollback)
   - Stop the session

5. **Test trait injection.** After multi-preview tests, test `preview_configure` on both macOS and iOS. The system appearance affects the default — test the **opposite** color scheme so the change is visually obvious (e.g., if the system is dark mode, test `colorScheme: "light"` and vice versa).
   - Start a macOS session (from the SPM example) and an iOS simulator session
   - Call `preview_configure` with the opposite `colorScheme` from the system default — verify the snapshot shows a clear visual difference (light background vs dark background)
   - Call `preview_configure` with `dynamicTypeSize: "accessibility3"` — verify success and that colorScheme persists (merge semantics)
   - Take a snapshot — verify text appears larger
   - Call `preview_configure` with an invalid `dynamicTypeSize` (e.g., `"huge"`) — verify it returns an error listing valid values
   - Call `preview_configure` with only `sessionID` and no traits — verify it returns "No configuration changes specified."

6. **Test traits persist across preview switch.** Using one of the sessions from step 5 (with traits already configured):
   - Call `preview_switch` with `previewIndex: 1` — verify success
   - Take a snapshot — verify the empty state is rendered **with the configured traits still applied** (e.g., opposite color scheme background)
   - Switch back to `previewIndex: 0` — verify traits still persist
   - Stop the sessions

7. **Test PreviewProvider support.** Each example has a `ToDoProviderPreview.swift` file with a `PreviewProvider`-based preview using `Group` and `.previewDisplayName()`. Test it using the SPM example:
   - Call `preview_list` on `examples/spm/Sources/ToDo/ToDoProviderPreview.swift` — verify it shows two previews: `[0] Default` and `[1] Empty State` (extracted from `.previewDisplayName()`)
   - Start a macOS session on the same file (default `previewIndex: 0`) — verify it compiles and renders
   - Take a snapshot — verify it shows the full item list (same as `#Preview` with `Item.samples`)
   - Call `preview_switch` with `previewIndex: 1` — verify it switches to the empty state
   - Take a snapshot — verify empty state (0/0 progress, no item rows)
   - Stop the session
   - **For one non-SPM example** (e.g., xcodeproj), also call `preview_list` on its `ToDoProviderPreview.swift` with the appropriate `projectPath` — verify it also shows two previews. Start a session and take a snapshot to confirm rendering works across build systems.

8. **Report results.** For each example, report pass/fail per test step. Summarize at the end.

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

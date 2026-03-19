---
name: integration-test
description: Run integration tests against example projects in the examples/ directory. Use when the user wants to validate PreviewsMCP's build system support, rendering, interaction, or hot-reload end-to-end.
argument-hint: [example-name]
allowed-tools: Bash, Read, Glob, Grep, preview_start, preview_snapshot, preview_elements, preview_touch, preview_stop, simulator_list
---

Run integration tests for PreviewsMCP example projects.

## Arguments

- `$ARGUMENTS` — optional example name (e.g., `spm`). If omitted, run all examples.

## Steps

1. **Discover examples.** List directories under `examples/` in the repo root. If `$ARGUMENTS` is provided, filter to that example only. If the specified example doesn't exist, report the error and list available examples.

2. **Build PreviewsMCP.** Run `swift build` from the repo root. If the build fails, stop and report the error.

3. **For each example**, read its `README.md` and follow the "Integration Test Prompt" section. The README contains the exact steps to execute, including which MCP tools to call and what to verify.

4. **Report results.** For each example, report pass/fail per test step. Summarize at the end.

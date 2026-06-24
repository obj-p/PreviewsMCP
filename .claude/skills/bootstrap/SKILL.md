---
name: bootstrap
description: Set up the development environment for this repository. Installs dependencies via Homebrew, configures git hooks, and builds the project with Bazel. Pass `--examples` to also install dependencies for the example projects (Bazel, Xcode).
allowed-tools: Bash, Read, Glob
---

Bootstrap the PreviewsMCP development environment.

## Arguments

- `--examples` — Also install dependencies and build the example projects (Bazel and Xcode).

## Steps

1. **Install dependencies.** Run `brew bundle` from the repo root to install tools from the `Brewfile` (just `bazelisk`; the lint/format tools are hermetic Bazel downloads under `//tools/lint`). If `brew` is not available, report the error and list what needs to be installed manually.

2. **Configure git hooks.** Run `git config core.hooksPath .githooks` to activate the pre-commit hook, which lints staged files via `bazel run //tools/lint:staged`.

3. **Build the project.** Run `bazel build //...` from the repo root. The first build compiles the Swift-fork LLVM from source (~3-4 min); it is pinned, so later builds reuse it. If the build fails, stop and report the error.

4. **Bazel example (if `--examples`).** Set up bazelisk: run `cd examples/bazel && mise install` (requires mise) or `brew install bazelisk`. Verify with `cd examples/bazel && bazel build //Sources/ToDo`.

5. **Xcode example (if `--examples`).** Install Mint and XcodeGen: run `brew install mint && cd examples/xcodeproj && mint bootstrap`. Generate the project with `mint run xcodegen generate`. Verify with `xcodebuild build -project ToDo.xcodeproj -scheme ToDo -destination 'platform=macOS'`.

6. **Verify setup.** Run `bazel --version` and `swift --version` to confirm tool availability, and `bazel run //tools/lint:check` to confirm the hermetic lint tools fetch and pass. If `--examples` was passed, also verify `mint version`.

7. **Report.** Summarize what was set up and confirm the environment is ready.

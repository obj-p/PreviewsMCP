---
name: bootstrap
description: Set up the development environment for this repository. Installs dependencies via Homebrew, configures git hooks, and builds the project. Pass `--examples` to also install dependencies for the example projects (Bazel, Xcode). Pass `--jit` to build the LLVM and orc-runtime dependencies the JIT executor links.
allowed-tools: Bash, Read, Glob
---

Bootstrap the PreviewsMCP development environment.

## Arguments

- `--examples` — Also install dependencies and build the example projects (Bazel and Xcode).
- `--jit` — Also build the LLVM and orc-runtime archives the JIT executor links, via `scripts/build-jit-llvm.sh`. Opt-in and slow (a multi-GB sparse clone plus build). Only contributors working on the JIT executor need this.

## Steps

1. **Install dependencies.** Run `brew bundle` from the repo root to install tools from the `Brewfile` (swift-format and swiftlint). If `brew` is not available, report the error and list what needs to be installed manually.

2. **Configure git hooks.** Run `git config core.hooksPath .githooks` to activate the pre-commit formatting hook.

3. **Build the project.** Run `swift build` from the repo root. If the build fails, stop and report the error.

4. **JIT dependencies (if `--jit`).** Ensure `cmake` and `ninja` are installed (`brew install cmake ninja`). Run `scripts/build-jit-llvm.sh` from the repo root to build the Swift-fork LLVM and orc runtime into `third_party/` (gitignored, opt-in, slow). Verify with `swift test --filter PreviewsJITLinkTests`.

5. **Bazel example (if `--examples`).** Set up bazelisk: run `cd examples/bazel && mise install` (requires mise) or `brew install bazelisk`. Verify with `cd examples/bazel && bazel build //Sources/ToDo`.

6. **Xcode example (if `--examples`).** Install Mint and XcodeGen: run `brew install mint && cd examples/xcodeproj && mint bootstrap`. Generate the project with `mint run xcodegen generate`. Verify with `xcodebuild build -project ToDo.xcodeproj -scheme ToDo -destination 'platform=macOS'`.

7. **Verify setup.** Run `swift-format --version`, `swiftlint version`, and `swift --version` to confirm tool availability. If `--examples` was passed, also verify `bazel --version` and `mint version`.

8. **Report.** Summarize what was set up and confirm the environment is ready.

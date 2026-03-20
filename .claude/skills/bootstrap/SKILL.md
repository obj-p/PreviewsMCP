---
name: bootstrap
description: Set up the development environment for this repository. Installs dependencies via Homebrew, configures git hooks, and builds the project.
allowed-tools: Bash, Read, Glob
---

Bootstrap the PreviewsMCP development environment.

## Steps

1. **Install dependencies.** Run `brew bundle` from the repo root to install tools from the `Brewfile` (currently swift-format). If `brew` is not available, report the error and list what needs to be installed manually.

2. **Configure git hooks.** Run `git config core.hooksPath .githooks` to activate the pre-commit formatting hook.

3. **Build the project.** Run `swift build` from the repo root. If the build fails, stop and report the error.

4. **Bazel example (optional).** If the user is working on the Bazel example, also set up bazelisk: run `cd examples/bazel && mise install` (requires mise) or `brew install bazelisk`. Verify with `cd examples/bazel && bazel build //Sources/ToDo`.

5. **Verify setup.** Run `swift-format --version` and `swift --version` to confirm tool availability. Report the installed versions.

6. **Report.** Summarize what was set up and confirm the environment is ready.

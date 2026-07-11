# AGENTS.md

Project instructions for any AI coding agent (Claude Code, Codex, Cursor, Aider, …) working in this repo. User-facing usage — install, CLI subcommands, `--json`, traits, variants, setup plugin, touch injection — lives in [README.md](README.md). This file is the build/test/merge workflow and the architecture an agent needs to change code safely.

## Project

PreviewsMCP renders SwiftUI `#Preview` blocks outside Xcode on both macOS and the iOS simulator, with hot-reload, touch interaction, and accessibility-tree inspection, driven from a CLI and an MCP server.

## Build, test, lint

Bazel (via [bazelisk](https://github.com/bazelbuild/bazelisk)) is the **one** build for development, tests, CI, and lint. Do not validate a change with `swift build` / `swift test` (see the Package.swift note below).

```bash
brew bundle                                          # bazelisk; lint tools are hermetic via //tools/lint
git config core.hooksPath .githooks                  # activate pre-commit formatting hook
bazel build //...                                    # first build compiles Swift-fork LLVM from source (~3-4 min), then pinned
bazel test //previewsmcp/Tests/...                   # all test suites
bazel test //previewsmcp/Tests/PreviewsJITLinkTests  # one suite
bazel run //previewsmcp/cli:previewsmcp -- --version # run the CLI
bazel run //tools/lint:format                        # auto-fix formatting (SwiftFormat, clang-format, buildifier)
bazel run //tools/lint:check                         # verify everything; the merge gate runs this
bazel run //tools/lint:staged                        # verify only staged files (what the pre-commit hook runs)
```

Or run `/bootstrap` in Claude Code.

The first build compiles the Swift-fork LLVM from source via `rules_foreign_cc` (pinned, reused after). The iOS JIT resources (`server.o`, `liborc_rt_iossim.a`, the LLVM TargetProcess libs) and the `PreviewAgent` executor build and wire through runfiles automatically — no helper scripts.

Lint runs through hermetic, Bazel-pinned tools under `//tools/lint`, so only `bazelisk` is needed and a local commit can never disagree with the gate on tool versions: SwiftFormat (`.swiftformat`, owns formatting), SwiftLint (`.swiftlint.yml`, non-strict, semantic rules only — cyclomatic complexity, function length, nesting), clang-format (`.clang-format`), and buildifier for Starlark. SwiftFormat's `hoistTry`, `hoistAwait`, and `preferKeyPath` are disabled because they produced invalid or compiler-crashing Swift — re-verify the full build, not just lint, before re-enabling them.

**Package.swift is not a build path.** It publishes exactly one library, `PreviewsSetupKit`, for external SwiftPM consumers, and feeds the Bazel build (`rules_swift_package_manager` reads it to sync external dependencies). It does **not** contain the CLI, engine, or test targets, so `swift build` / `swift test` compile a near-empty package and pass without exercising any code you changed — a false positive. Build and test only via the Bazel commands above.

## Architecture

```
previewsmcp/             # umbrella for all first-party Bazel-built code (one dir per module)
├── SimulatorBridge/     # ObjC — runtime-loads CoreSimulator.framework (no build-time linking)
├── PreviewsCore/        # platform-agnostic: parser, compiler, bridge gen, differ, file watcher
├── PreviewsMacOS/       # macOS host: NSApplication + NSWindow + Snapshot (runs inside the daemon)
├── PreviewsIOS/         # iOS simulator: SimulatorManager, IOSAgentBuilder, IOSPreviewSession
├── PreviewsEngine/      # cross-platform engine wiring PreviewsCore + iOS/macOS hosts
├── PreviewsJITLink/     # Swift JIT-link layer (+ PreviewsJITLinkCxx C++ shim)
├── PreviewsCLI/         # CLI (ArgumentParser) + daemon + MCP server (swift-sdk) — a library
├── PreviewAgent/        # C++ in-process JIT executor binary
├── cli/                 # thin executable shim → //previewsmcp/cli:previewsmcp
├── ios-host/            # iOS agent/shell/executor app source, embedded at session start
└── Tests/               # all unit + integration test suites

Sources/PreviewsSetupKit/  # the only SwiftPM-exposed library (the PreviewSetup plugin protocol)
```

- **PreviewsCore** has no platform-specific dependencies (no AppKit, no CoreSimulator).
- **SimulatorBridge** is ObjC because it uses `objc_lookUpClass` / protocol casts for private-API access; **PreviewsIOS** depends on it, and touch injection runs in-app via the Hammer approach (IOHIDEvent + `BKSHIDEventSetDigitizerInfo`).
- **PreviewsCLI is a `swift_library`, not an executable**, so the test targets can `@testable import PreviewsCLI`; `previewsmcp/cli/` is a three-line shim that calls `PreviewsMCPApp.main()` and exists only to be the executable product. Match the `previewsmcp` directory/target naming if `PreviewsCLI` is sliced further.
- **iOS agent-app source is real Swift** in `previewsmcp/ios-host/agent/` (`AgentApp.swift`, `Info.plist`, `AppIcon.png`), with the shell app alongside in `previewsmcp/ios-host/shell/`. The `embed_host_app_source` rule (`bazel/embed.bzl`, wired in `bazel/embed/BUILD.bazel`) reads those files and emits `IOSHostAppSource.generated.swift`, which defines the `IOSAgentAppSource` enum exposing them as base64 constants. `IOSAgentBuilder` writes the source out at session start and compiles it with swiftc targeting arm64-apple-ios-simulator. Byte-equivalence is pinned by `IOSAgentBuilderHashTests`.

### Daemon model

All CLI subcommands except `serve` are **daemon clients** — they connect to a background daemon over a Unix domain socket at `~/.previewsmcp/serve.sock`. The daemon auto-starts on first CLI invocation (ADB-style) and persists across commands. CLI convention: read-oriented commands write data/JSON to **stdout** and progress/logs to **stderr**; imperative commands write confirmations to stderr only, keeping stdout clean for piping.

Key files:
- `DaemonClient.swift` — auto-start + connect via `withDaemonClient(name:body:)`; registers a stderr log-forwarder for `LogMessageNotification` before the MCP handshake.
- `DaemonListener.swift` — POSIX UDS accept loop (`DaemonSocket`), per-connection `PreviewsMCPServer` over `FramedTransport`.
- `DaemonLifecycle.swift` — PID file, `setsid()` detachment, signal handlers.
- `SessionResolver.swift` — resolves `--session <uuid>` / `--file <path>` / sole-running-session targeting.
- `DaemonProtocol.swift` — shared `Codable` DTOs for `structuredContent` payloads on tool responses.

`PreviewsMCPApp.swift` routes commands: only `serve` runs `NSApplication`; everything else uses `dispatchMain()` + async `Task`.

### Stdio server vs UDS daemon

`previewsmcp serve` runs in two modes that are **separate processes with separate session state**:

- **Stdio** (default) — spawned by MCP clients via `.mcp.json` (Claude Code, Cursor). Self-contained: own `PreviewHost`, `IOSSessionManager`, `ConfigCache`. Resident for the lifetime of the MCP host process.
- **UDS daemon** (`--daemon`) — auto-spawned by every CLI subcommand at `~/.previewsmcp/serve.sock`. Persists across CLI invocations.

A session created via MCP tools lives in the stdio process and is **not** visible to `previewsmcp list` / `snapshot --session-id …` (which talk to the daemon), and vice versa.

When validating code changes, both halves can go stale — `bazel build` overwrites the binary, but resident processes keep running the old code:

- Refresh stdio: `/exit` and relaunch Claude Code (or call `preview_build_info` — `stale: true` means the on-disk binary was rebuilt since the running process started).
- Refresh daemon: `previewsmcp kill-daemon` (auto-respawns on the next CLI invocation; #142's version-mismatch handshake also restarts it transparently).

The stdio server has no equivalent of #142's handshake — there's no peer to handshake with — so staleness must be detected client-side.

**Worktrees (#154):** open Claude Code from inside the worktree directory, not via `/resume` from the main repo. `/resume` preserves the original project root, so the stdio MCP server keeps pointing at the main repo's `bazel-bin/...` binary regardless of where you re-launched. Fresh launches in each worktree resolve the relative `.mcp.json` command path correctly. The integration-test skill's Step 2 catches the mismatch automatically if you forget.

## Key conventions

- Swift 6.0 strict concurrency — actors for shared state, `Sendable` structs for cross-isolation data.
- Private framework access: runtime-load via `Bundle(path:).loadAndReturnError()` + `objc_lookUpClass()`, never build-time link.
- Old dylibs/views are retained (never `dlclose`) to prevent `EXC_BAD_ACCESS`.
- `.tag()` integer literals are excluded from `ThunkGenerator` to avoid Int/CGFloat overload ambiguity.
- All custom `Error` types conform to `LocalizedError` with `errorDescription` (not just `CustomStringConvertible`) so the MCP server reports useful messages.

## MCP server

Binary: `scripts/previewsmcp serve` (builds `//previewsmcp/cli:previewsmcp` via bazelisk, then execs it).
Config: `.mcp.json` at the repo root — Claude Code auto-spawns the stdio server from it at session start, which is what the `mcp__previewsmcp__*` tools and the `integration-test` skill reach.

Tools: `preview_list`, `preview_start`, `preview_configure`, `preview_switch`, `preview_variants`, `preview_snapshot`, `preview_elements`, `preview_touch`, `preview_stop`, `simulator_list`, `session_list`, `preview_build_info`. Handlers that return non-trivial data emit a `structuredContent` payload (Codable DTOs from `DaemonProtocol.swift`) alongside the text content blocks, so agents can skip parsing prose.

## Git & merge workflow

`main` is branch-protected — every change goes through a PR. Create a feature branch before committing; use a worktree when working in parallel with other agents to avoid conflicts.

CI (self-hosted Mac mini runner: `bazel run //tools/lint:check` + `bazel test //...`, ~9 min warm) is a **non-required, corroborating signal** — `required_status_checks` is not on the `main` ruleset, so nothing gates a merge automatically. Local verification is the gate, and you run all of it.

Merge checklist — a green CI check is corroborating, not a substitute:

1. `/simplify` then `/code-review` on each chunk of your diff.
2. `bazel run //tools/lint:check` clean.
3. Full local suite: `bazel test //previewsmcp/Tests/...` (all unit suites) plus the `integration-test` skill for the example end-to-end coverage. No CI shortcut. (`swift test` is not a fallback — see the Package.swift note.)
4. Classify each failure as yours-vs-preexisting; a preexisting failure on `main` is not a blocker, but say so explicitly.
5. Stage explicit paths (`git add <path> …`) — never `git add -A`.
6. Un-draft the PR, then squash-merge your own PR.

## Test architecture

- **DaemonTestLock** serializes daemon-touching tests across suites via blocking `flock(LOCK_EX)` on `DispatchQueue.global` — NOT non-blocking polling with `Task.sleep`, which starves Swift's cooperative pool on runners with small pools (~3-4 threads) and deadlocks. `@Suite(.serialized)` only orders tests within one suite, not across suites or test targets — DaemonTestLock fills that gap. The lock file, `serve.log`, and the socket all live under `DaemonTestLock.effectiveSocketDir`.
- **Per-run daemon socket dir (#283).** `DaemonTestLock.effectiveSocketDir` resolves `PREVIEWSMCP_SOCKET_DIR` → a short `/tmp/pmcp-<hash>` keyed off `$TEST_TMPDIR` → system temp. Bazel sets `TEST_TMPDIR` unique per test target, so the hash makes the socket dir unique per target with no hand-allocated literal. We hash to `/tmp/pmcp-<hash>` instead of nesting under `$TEST_TMPDIR` because a UDS path is capped at 104 bytes (`sun_path`) on macOS and `$TEST_TMPDIR` is already ~140 chars deep — `bind()` would silently fail. The harness (`MCPTestServer.start`, `CLIRunner`, `DaemonLifecycleTests`, `RunCommandTests`, `VersionHandshakeTests`, `LogsCommandTests`) exports this value as `PREVIEWSMCP_SOCKET_DIR` into every spawned daemon/CLI so production `DaemonPaths` picks it up — any test that spawns the binary directly must do the same or it resolves a different socket than its probes. Production `DaemonPaths` must NOT honor `TEST_TMPDIR`; that rung lives only in the test-side resolver. New daemon-touching targets get isolation automatically — do NOT add a hand-allocated `PREVIEWSMCP_SOCKET_DIR` literal (an explicit one still wins if a specific path is ever required). The dir is not auto-deleted but is stale-safe: `cleanSlate()` + the daemon's connect-probe single-instance guard reclaim leftovers.
- **Bidirectional MCP-ping liveness.** Both sides of the daemon channel run the shared missed-pong loop in `PingLiveness.swift`: the client pings every 5s and disconnects after 6 missed pongs (~30s wedged-daemon bound; see `DaemonClient.openClient`), the daemon pings every 60s and disconnects after 3 (dead-client backstop; see `DaemonListener`). ANY inbound frame counts as life. A client-side disconnect drains pending requests, so the body's `callTool` awaits throw a transport error rather than hanging forever. There is NO unsolicited server traffic on an idle connection. Do NOT emit unsolicited `ProgressNotification`s — without a `progressToken` they are out-of-spec; use `server.log(level:,logger:,data:)`.
- **`MCPTestServer.withTimeout` and its watchdog both run on detached real pthreads, never `Task.sleep`/`DispatchSource`/GCD.** When the MCP SDK's transport loop busy-spins on a wedged server (#135), the cooperative pool and libdispatch-QoS workers are starved and those timers never fire; a raw pthread with `Thread.sleep` blocks in the kernel and survives. `withTimeout` races `body` against the pthread, which resumes a shared `CheckedContinuation` (a synchronous primitive) and calls `process.terminate()` on the server subprocess so daemon-side state doesn't leak into the next test. The always-on watchdog wakes every 60s and `fputs`-writes elapsed time + the server's stderr tail to the test process's stderr — silent under 60s, but a minute-by-minute trail when `.timeLimit` kills a hang.
- **The daemon needs a window server** (`NSApplication.shared` + `NSHostingView` to render). If daemon-touching tests hang with zero output, check whether `CGMainDisplayID()` returns 0 — the daemon lost display access.

### iOS simulator tests

- **`SimulatorManager.bootDevice` blocks until the device is actually booted.** `SBDevice.boot()` returns as soon as boot *starts*; `bootDevice` then awaits `xcrun simctl bootstatus <udid> -b` (block until SpringBoard is up). Default timeout 180s.
- **Display attach is async vs. bootstatus** — the display subsystem wires ports after SpringBoard is up. `SimulatorManager.screenshotData` retries direct `SBCaptureFramebuffer` capture up to 5× with 2s backoff before falling back to `xcrun simctl io <udid> screenshot`.
- **Each sim-booting test resolves its own dedicated device via `SimulatorTestDevices` (#337).** Each test passes a distinct index and gets a harness-owned simulator `previewsmcp-test-<index>`, created on demand as an iPhone 17 on the newest installed iOS 26+ runtime (idempotent). Resolve while holding `SimulatorTestLock` (creation mutates the shared device set); add a new index for any new device-booting test and record it in the `SimulatorTestDevices` doc comment.
- **iPhones only, not iPads.** M-chip iPads have been observed exceeding 60s bootstatus; iPhones are reliable in the <15s window.
- **`AsyncProcessTimeout` drains the subprocess's pipes before throwing** (`runAsync(timeout:)` SIGTERMs then captures stdout/stderr), so logs show which stage stalled. CoreSimulator daemon state can still flake after rapid boot/shutdown cycles — `IOSPreviewSession.start()` retries transient boot failures.

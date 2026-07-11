# AGENTS.md

Project instructions for any AI coding agent (Claude Code, Codex, Cursor, Aider, …) working in this repo.

## Project

PreviewsMCP — standalone SwiftUI preview renderer with MCP server for AI-driven UI development. Renders `#Preview` blocks outside Xcode on both macOS and iOS simulator, with hot-reload, touch interaction, and accessibility tree inspection.

## Setup

Bazel (via [bazelisk](https://github.com/bazelbuild/bazelisk)) is the build for development, tests, and CI. SwiftPM is kept for external consumers of the library products (see [Consuming via SwiftPM](#consuming-via-swiftpm)).

```bash
brew bundle                              # Install tools (bazelisk; lint tools are hermetic via //tools/lint)
git config core.hooksPath .githooks      # Activate pre-commit formatting hook
bazel build //...                        # Build all targets (first build builds LLVM, ~3-4 min)
```

Or run `/bootstrap` in Claude Code.

## Build & Test

```bash
bazel build //...                                  # Build all targets
bazel test //previewsmcp/Tests/...                 # Run all test suites
bazel test //previewsmcp/Tests/PreviewsJITLinkTests  # Run a specific suite
bazel run //previewsmcp/cli:previewsmcp -- --version  # Run the CLI
```

The first `bazel build` compiles the Swift-fork LLVM from source via `rules_foreign_cc` (~3-4 min); it is pinned, so later builds reuse it. The iOS JIT resources (`server.o`, `liborc_rt_iossim.a`, the LLVM TargetProcess libs) and the `PreviewAgent` executor are built and wired through runfiles automatically — Bazel builds LLVM hermetically, so no helper scripts are needed.

Daemon-touching test suites use `DaemonTestLock` (flock) for cross-target serialization — `@Suite(.serialized)` only orders within a suite, not across test targets. The integration suites are tagged `local` (unsandboxed, like `swift test`) and `exclusive`.

### Consuming via SwiftPM

`Package.swift` stays the published manifest so other Swift projects can depend on the library products (notably `PreviewsSetupKit`). It also feeds the Bazel build: `rules_swift_package_manager` reads it to sync external dependencies. SwiftPM still builds and tests the package directly (`swift build` / `swift test`), with the same coverage, as a fallback and for consumers.

## Formatting & Linting

Lint and format run through hermetic, Bazel-pinned tools under `//tools/lint`, so no host installs are needed (only `bazelisk`) and a local commit can never disagree with the merge gate on tool versions. The tools are [SwiftFormat](https://github.com/nicklockwood/SwiftFormat) (config: `.swiftformat`), [SwiftLint](https://github.com/realm/SwiftLint) (config: `.swiftlint.yml`), [clang-format](https://clang.llvm.org/docs/ClangFormat.html) (config: `.clang-format`), and [buildifier](https://github.com/bazelbuild/buildtools) for Starlark.

```bash
bazel run //tools/lint:format   # auto-fix formatting (SwiftFormat, clang-format, buildifier)
bazel run //tools/lint:check    # verify everything; the merge-queue gate runs this
bazel run //tools/lint:staged   # verify only git-staged files (what the pre-commit hook runs)
```

SwiftFormat owns formatting; SwiftLint runs non-strict and catches semantic issues (cyclomatic complexity, function length, nesting depth) with the overlapping formatting rules disabled. SwiftFormat's `hoistTry`, `hoistAwait`, and `preferKeyPath` rules are disabled in `.swiftformat` because they produced invalid or compiler-crashing Swift; re-verify the full build, not just lint, before re-enabling them.

## Architecture

```
previewsmcp/             # Umbrella for all first-party Bazel-built code (one dir per module)
├── SimulatorBridge/     # ObjC — runtime-loads CoreSimulator.framework (no build-time linking)
├── PreviewsCore/        # Platform-agnostic: parser, compiler, bridge gen, differ, file watcher
├── PreviewsMacOS/       # macOS host: NSApplication + NSWindow + Snapshot (runs inside the daemon)
├── PreviewsIOS/         # iOS simulator: SimulatorManager, IOSAgentBuilder, IOSPreviewSession
├── PreviewsEngine/      # Cross-platform engine wiring PreviewsCore + iOS/macOS hosts
├── PreviewsJITLink/     # Swift JIT-link layer (+ PreviewsJITLinkCxx C++ shim)
├── PreviewsCLI/         # CLI (ArgumentParser) + daemon + MCP server (swift-sdk) — library target
├── PreviewAgent/        # C++ in-process JIT executor binary
├── cli/                 # Thin executable shim (Bazel target //previewsmcp/cli:previewsmcp)
├── ios-host/            # iOS agent/shell/executor app source embedded at session start
└── Tests/               # All unit + integration test suites

Sources/
└── PreviewsSetupKit/    # Setup plugin protocol (PreviewSetup) — the only SwiftPM-exposed library
```

`PreviewsCLI` is a library, not an `executableTarget`, so the test targets in `previewsmcp/Tests/PreviewsCLITests/` and `previewsmcp/Tests/MCPIntegrationTests/` can `@testable import PreviewsCLI` under both `swift test` and Xcode-driven SPM builds (Xcode's dependency scanner refuses to expose an executable target's swiftmodule to dependent tests, which broke `xcodebuild build-for-testing` before PR #184). `previewsmcp/cli/` is a three-line shim that imports `PreviewsCLI` and calls `PreviewsMCPApp.main()` — the only purpose of that target is to be the executable product. Match the `previewsmcp` directory/target naming if `PreviewsCLI` is sliced further (see `prompts/modularization.md` on the `previews-research` branch).

- **PreviewsCore** has no platform-specific dependencies (no AppKit, no CoreSimulator)
- **SimulatorBridge** is ObjC because it uses `objc_lookUpClass` / protocol casts for private API access
- **PreviewsIOS** depends on SimulatorBridge; touch injection runs in-app via Hammer approach (IOHIDEvent + BKSHIDEventSetDigitizerInfo)
- **iOS agent-app source lives in `previewsmcp/ios-host/agent/`** (`AgentApp.swift`, `Info.plist`, `AppIcon.png`), with the shell app alongside it in `previewsmcp/ios-host/shell/`. The `embed_host_app_source` rule (driven by `bazel/embed.bzl`, wired in `bazel/embed/BUILD.bazel`) reads those files and emits `IOSAgentAppSource.generated.swift` exposing them as `IOSAgentAppSource.code` / `.infoPlist` / `IOSAppIconData.bytes` (base64-encoded). `IOSAgentBuilder` writes the source out at session start and compiles it with swiftc targeting arm64-apple-ios-simulator. Byte-equivalence with the previous stringified blob is pinned by `IOSAgentBuilderHashTests`.

### Daemon model

All CLI subcommands except `serve` are **daemon clients** — they connect to a background daemon process over a Unix domain socket at `~/.previewsmcp/serve.sock`. The daemon auto-starts on first CLI invocation (ADB-style) and persists across commands.

Key files:
- `DaemonClient.swift` — auto-start + connect via `withDaemonClient(name:body:)`. Registers a stderr log-forwarder for `LogMessageNotification` before the MCP handshake.
- `DaemonListener.swift` — POSIX UDS accept loop (`DaemonSocket`), per-connection `PreviewsMCPServer` over `FramedTransport`.
- `DaemonLifecycle.swift` — PID file, `setsid()` detachment, signal handlers.
- `DaemonProbe.swift` — socket liveness check (connect + immediate close).
- `SessionResolver.swift` — resolves `--session <uuid>` / `--file <path>` / sole-running-session targeting.
- `DaemonProtocol.swift` — shared `Codable` DTOs for `structuredContent` payloads on tool responses.
- `MCPContentHelpers.swift` — `Value.decode(_:)`, the `DaemonToolCalling` seam, `emitJSON(...)`.
- `SessionTargetingOptions.swift` — shared `@OptionGroup` for `--session` / `--file`.

`PreviewsMCPApp.swift` routes commands: only `serve` runs `NSApplication`; everything else uses `dispatchMain()` + async `Task`.

### Stdio server vs UDS daemon

`previewsmcp serve` runs in two modes that are **separate processes with separate session state**:

- **Stdio** (default) — spawned by MCP clients via `.mcp.json` (Claude Code, Cursor). Self-contained: own `PreviewHost`, `IOSSessionManager`, `ConfigCache`. Resident for the lifetime of the MCP host process.
- **UDS daemon** (`--daemon`) — auto-spawned by every CLI subcommand at `~/.previewsmcp/serve.sock`. Persists across CLI invocations.

A session created via MCP tools lives in the stdio process and is **not** visible to `previewsmcp list` / `snapshot --session-id …` (which talk to the daemon). And vice versa.

When validating code changes, both halves can go stale — `swift build` overwrites the binary, but resident processes keep running the old code:

- Refresh stdio: `/exit` and relaunch Claude Code (or call `preview_build_info` to detect staleness — `stale: true` means the on-disk binary has been rebuilt since the running process started).
- Refresh daemon: `previewsmcp kill-daemon` (auto-respawns on next CLI invocation; #142's version-mismatch handshake also restarts it transparently).

The stdio server has no equivalent of #142's handshake — there's no peer to handshake with — so the staleness must be detected client-side.

**Worktrees (#154):** open Claude Code from inside the worktree directory, not via `/resume` from the main repo. `/resume` preserves the original project root, so the stdio MCP server keeps pointing at the main repo's `.build/...` binary regardless of where you re-launched. Fresh launches in each worktree resolve the relative `.mcp.json` command path correctly. The integration-test skill's Step 2 catches the mismatch automatically if you forget.

### CLI subcommands

| Command | Purpose | Daemon? |
|---------|---------|---------|
| `run` | Start a live preview session (attached or `--detach`) | client |
| `snapshot` | Screenshot a preview (reuses existing session or ephemeral) | client |
| `variants` | Multi-trait screenshot sweep | client |
| `list` | Enumerate `#Preview` blocks in a file | local |
| `configure` | Change traits on a live session | client |
| `switch` | Switch active `#Preview` block | client |
| `elements` | Dump iOS accessibility tree as JSON | client |
| `touch` | Inject tap or swipe on iOS simulator | client |
| `simulators` | List available iOS simulator devices | client |
| `stop` | Close one or all sessions (`--all`) | client |
| `status` | Check daemon liveness | local |
| `kill-daemon` | Stop the daemon process | local |
| `serve` | Start the daemon (usually auto-started) | IS the daemon |

### Structured output (`--json`)

Seven read-oriented commands support `--json` for scripts and agent consumption: `run --detach`, `snapshot`, `variants`, `list`, `status`, `simulators`, `elements`. When `--json` is set, stdout gets one JSON document; progress/log messages still go to stderr. Imperative commands (`stop`, `touch`, `configure`, `switch`) do not get `--json`.

The daemon also populates `CallTool.Result.structuredContent` alongside text content blocks on 7 MCP tool handlers. CLI commands decode `structuredContent` via `Value.decode(T.self)` using the DTOs from `DaemonProtocol.swift` — no regex parsing of prose.

### Output streams

CLI commands follow a stdout-for-data, stderr-for-side-effects convention:

- **Read-oriented** commands (`list`, `status`, `simulators`, `elements`, `snapshot`, `variants`, `run --detach`) write their primary output (data, JSON, session ID) to **stdout**. Progress and log messages go to stderr.
- **Imperative** commands (`configure`, `switch`, `touch`, `stop`) write confirmation messages to **stderr** only, keeping stdout clean for piping.
- Daemon log forwarding (`LogMessageNotification` → stderr) applies to all daemon-client commands.

## Key Conventions

- Swift 6.0 strict concurrency — actors for shared state, Sendable structs for cross-isolation data
- Private framework access: runtime-load via `Bundle(path:).loadAndReturnError()` + `objc_lookUpClass()`, never build-time link
- iOS agent app source is real Swift in `previewsmcp/ios-host/agent/AgentApp.swift` (lintable, formatable, compile-checked); the `embed_host_app_source` rule embeds it as a base64 constant for runtime compilation with swiftc targeting arm64-apple-ios-simulator
- Old dylibs/views are retained (never dlclose) to prevent EXC_BAD_ACCESS
- `.tag()` integer literals are excluded from ThunkGenerator to avoid Int/CGFloat overload ambiguity
- All custom Error types must conform to `LocalizedError` with `errorDescription` (not just `CustomStringConvertible`) so MCP server reports useful messages

## MCP Server

Binary: `scripts/previewsmcp serve` (builds `//previewsmcp/cli:previewsmcp` via bazelisk, then execs it)
Config: `/.mcp.json` (in parent directory)

Tools: `preview_list`, `preview_start`, `preview_configure`, `preview_switch`, `preview_variants`, `preview_snapshot`, `preview_elements`, `preview_touch`, `preview_stop`, `simulator_list`, `session_list`, `preview_build_info`

All tool handlers that return non-trivial data emit a `structuredContent` payload (Codable DTOs from `DaemonProtocol.swift`) alongside the human-readable text content blocks. Agents that consume `structuredContent` can skip parsing prose.

## Trait Injection

`preview_configure` and `preview_start` accept these trait parameters to render previews under different SwiftUI traits:

| Trait | Values | SwiftUI modifier |
|-------|--------|-----------------|
| `colorScheme` | `"light"`, `"dark"` | `.preferredColorScheme()` |
| `dynamicTypeSize` | `"xSmall"` through `"accessibility5"` | `.dynamicTypeSize()` |
| `locale` | BCP 47 identifier (e.g., `"en"`, `"ar"`, `"ja-JP"`) | `.environment(\.locale, ...)` |
| `layoutDirection` | `"leftToRight"`, `"rightToLeft"` | `.environment(\.layoutDirection, ...)` |
| `legibilityWeight` | `"regular"`, `"bold"` | `.environment(\.legibilityWeight, ...)` |

Traits are injected as view modifiers in the generated bridge code. Changing traits triggers a full recompile (@State is lost). Traits persist across hot-reload cycles and preview switches. Pass an empty string `""` to clear a previously set trait.

`locale` is not validated against a fixed list — any non-empty string is accepted. `layoutDirection` and `legibilityWeight` are validated against their respective enum values.

## Multi-Preview Support

Files with multiple `#Preview` blocks are fully supported. `preview_list` shows all previews with closure body snippets. `preview_start` accepts a `previewIndex` parameter (default 0) and returns the full list of available previews. `preview_switch` changes which preview is rendered in a running session without tearing down the session — traits persist across switches, @State is reset. If a switch fails (e.g., invalid index), the session rolls back to the previous preview.

**macOS limitation:** `dynamicTypeSize` has no visible effect on macOS. macOS does not have a system-level Dynamic Type feature, and `NSHostingView` does not scale fonts in response to the `.dynamicTypeSize()` modifier. Use iOS simulator previews to test dynamic type sizes. `colorScheme` works on both platforms.

## Variant Capture

`preview_variants` captures screenshots under multiple trait configurations in a single MCP call. Pass preset names (`"light"`, `"dark"`, `"xSmall"` through `"accessibility5"`, `"rtl"`, `"ltr"`, `"boldText"`) or JSON object strings for custom combinations (e.g., `{"colorScheme":"dark","locale":"ar","layoutDirection":"rightToLeft","label":"dark-arabic"}`). The session's original traits are restored after all variants are captured. Each variant triggers a recompile.

## Project Config

A `.previewsmcp.json` file at the project root sets defaults for all CLI commands and MCP tool calls. All fields are optional.

```json
{
  "platform": "ios",
  "device": "iPhone 16 Pro",
  "traits": {
    "colorScheme": "dark",
    "dynamicTypeSize": "large",
    "locale": "en"
  },
  "quality": 0.9,
  "setup": {
    "moduleName": "MyAppPreviewSetup",
    "typeName": "AppPreviewSetup"
  }
}
```

**Precedence:** explicit MCP/CLI parameter > config file > built-in default. The config file is auto-discovered by walking up from the source file directory. CLI commands accept `--config <path>` to override auto-discovery.

The `device` field accepts either a device name (e.g., `"iPhone 16 Pro"`) or a UDID.

## Setup Plugin

`PreviewsSetupKit` is a zero-dependency SwiftUI-only library that ships the `PreviewSetup` protocol. It replaces micro apps / dev apps by providing the same mock dependency setup and theme wrapping without maintaining a separate app target.

**Two methods, two lifecycles:**

| Method | When | Survives hot-reload? | Use case |
|--------|------|---------------------|----------|
| `setUp()` | Once per session, before first preview | Yes | Firebase init, auth, fonts, DI container |
| `wrap(_:)` | Every dylib load | N/A | Theme providers, environment values |

`setUp()` is `async throws` and runs completely outside the hot-reload path. If it throws, the preview renders without setup and the error is reported as a warning. Trait modifiers from `preview_configure` are applied outside the wrap, so explicit overrides always take precedence.

The setup target is declared in `.previewsmcp.json` via `setup.moduleName`, `setup.typeName`, and `setup.packagePath` (relative to config file). PreviewsMCP builds the setup package independently via `SetupBuilder` — the user's app target has no dependency on PreviewsMCP. Standalone mode (no build system) ignores the setup config with a warning.

## iOS Touch Injection

Uses Hammer approach (in-app, headless, no mouse movement):
1. IOKit: `IOHIDEventCreateDigitizerFingerEvent` (transducerType=3)
2. BackBoardServices: `BKSHIDEventSetDigitizerInfo` with `UIWindow._contextId`
3. UIKit: `UIApplication._enqueueHIDEvent:`

All loaded via dlopen/dlsym inside the iOS host app. Does NOT use IndigoHID/SimulatorKit (those create pointer events, not touch events on Xcode 26.2).

## Git Workflow

The `main` branch has branch protections — all changes must go through a pull request. Always create a feature branch before committing. Use worktrees when working in parallel with other agents to avoid conflicts.

### Verifying a PR before merge

CI runs on a self-hosted Mac mini runner (`bazel test //...` + `bazel run //tools/lint:check`, ~9 min warm) but is a **non-required signal** while it builds a track record — the `required_status_checks` rule is not yet on the `main` ruleset, so nothing gates a merge automatically. Verification is local and mandatory: a PR does **not** merge until **all unit tests pass** and **the example integration tests pass via the `integration-test` skill**. Run the suites with `bazel test //previewsmcp/Tests/...`, then run the `integration-test` skill for the example end-to-end coverage. (`swift test` still works as a fallback; pass `--filter PreviewsJITLinkTests --no-parallel` for the JIT tests there.) A green CI check is corroborating, not sufficient.

## Test Notes

### Test architecture

- **DaemonTestLock** serializes daemon-touching tests across suites via `flock`. Uses blocking `flock(LOCK_EX)` on `DispatchQueue.global` — NOT non-blocking polling with `Task.sleep`, which starves Swift's cooperative thread pool on CI runners with small pools (~3-4 threads) and causes deadlocks. The lock file, `serve.log`, and the daemon socket all live under `DaemonTestLock.effectiveSocketDir` so concurrent jobs get separate state.
- **Per-run daemon socket dir (#283).** `DaemonTestLock.effectiveSocketDir` resolves `PREVIEWSMCP_SOCKET_DIR` → a short `/tmp/pmcp-<hash>` keyed off `$TEST_TMPDIR` → system temp. Bazel sets `TEST_TMPDIR` unique per test target, so the hash makes the socket dir unique per target with NO hand-allocated `PREVIEWSMCP_SOCKET_DIR` literal. We hash to `/tmp/pmcp-<hash>` instead of nesting under `$TEST_TMPDIR` because a Unix-domain socket path is capped at 104 bytes (`sun_path`) on macOS and `$TEST_TMPDIR` is already ~140 chars deep — `bind()` would silently fail. The harness (`MCPTestServer.start`, `CLIRunner`, `DaemonLifecycleTests`, `RunCommandTests`, `VersionHandshakeTests`, `LogsCommandTests`) EXPORTS this value as `PREVIEWSMCP_SOCKET_DIR` into EVERY spawned daemon/CLI so production `DaemonPaths` picks it up — any test that spawns the binary directly must do the same or it will resolve a different socket than its probes. Production `DaemonPaths` must NOT honor `TEST_TMPDIR` — the `$TEST_TMPDIR` rung lives only in the test-side resolver. The `/tmp/pmcp-<hash>` dir is not auto-deleted, but it is stale-safe: `cleanSlate()` + the daemon's connect-probe single-instance guard reclaim any leftover.
- **`@Suite(.serialized)`** only orders tests within a single suite. It does NOT serialize across suites or test targets. DaemonTestLock exists to fill that gap.
- **`MCPTestServer.withTimeout`** races `body` against a detached `Thread` (pthread) timer, NOT a `Task.sleep`-based one. When the MCP SDK's transport loop busy-spins on a wedged server (see issue #135), the cooperative pool is starved and `Task.sleep`-based timers never fire — the prior `withThrowingTaskGroup` implementation silently timed out at Swift Testing's `.timeLimit` with no diagnostic. The pthread resumes a shared `CheckedContinuation` directly, which is a synchronous primitive with no pool dependency. On timeout the pthread also calls `process.terminate()` on the server subprocess so the daemon-side state doesn't persist into the next test. Note: the body `Task` may leak if its pending MCP continuation never drains (SDK transport EOF does not resume `pendingRequests`; only `disconnect()` does) — acceptable cost for an already-failing test; the process exits shortly after.
- All daemon-touching tests share one daemon at `~/.previewsmcp/serve.sock` (or `PREVIEWSMCP_SOCKET_DIR` if set). Each suite calls `cleanSlate()` at the start to kill any leftover daemon; the daemon auto-starts on the first CLI command and persists within the suite.

### CI-specific concerns

- **CI is one `bazel` job** on the self-hosted Mac mini runner: `bazel run //tools/lint:check` then `bazel test //...`. There is no cross-job daemon contention — target isolation comes from the per-target socket dirs below.
- **Bazel daemon-touching test targets need NO `PREVIEWSMCP_SOCKET_DIR`** in their `swift_test` `env` — the harness derives a per-run, per-target socket dir from `$TEST_TMPDIR` (`DaemonTestLock.effectiveSocketDir`) and exports it into spawned daemons (#283). New daemon-touching targets get isolation automatically; do not add a hand-allocated literal. (An explicit `PREVIEWSMCP_SOCKET_DIR` still wins if a specific path is ever required.)
- **The daemon requires a window server** (`NSApplication.shared` + `NSHostingView` for rendering). The runner is a LaunchAgent in the mini's auto-login GUI session, which provides one — the daemon must not be spawned in a context that loses display access (e.g., certain `launchd` contexts). If tests hang with zero output, check whether `CGMainDisplayID()` returns 0.
- **Daemon startup is slow on CI** (~5-10s vs ~500ms locally). The `DaemonClient.connect(startTimeout:)` default is 30s to accommodate this.
- **Bidirectional MCP-ping liveness** — both sides of the daemon channel run the shared missed-pong loop in `PingLiveness.swift`: the client pings every 5s and disconnects after 6 missed pongs (~30s wedged-daemon bound; policy and rationale on `DaemonClient.openClient`), the daemon pings every 60s and disconnects after 3 (dead-client backstop; see `DaemonListener`). ANY inbound frame counts as life. A client-side disconnect drains pending requests, so the body's `callTool` awaits throw a transport error rather than hanging forever. There is NO unsolicited server traffic on an idle connection: the pre-stage-6 2s `logger: "heartbeat"` notification and the `StallTimer` actor are retired, and `registerStderrLogForwarder` filters the heartbeat logger only for stale pre-stage-6 daemons in the version-skew window. Do NOT emit unsolicited `ProgressNotification`s — without a `progressToken` they are out-of-spec; use `server.log(level:,logger:,data:)`.
- **MCPTestServer watchdog** — every active `MCPTestServer` spawns a detached `Thread` (real pthread) that wakes every 60s and writes the elapsed time plus the tail of the server's stderr to the test process's own stderr via `fputs`. Silent on the happy path (tests < 60s never emit), but when Swift Testing's `.timeLimit` kills a hanging MCP test the CI log contains a minute-by-minute trail of what the server subprocess was actually doing. The first implementation used `DispatchSource.makeTimerSource(qos: .utility)` — that produced no output in a real CI hang because libdispatch's utility-QoS workers were starved by whatever was burning cores. A raw pthread sidesteps QoS scheduling and Swift concurrency entirely; `Thread.sleep` blocks in the kernel rather than suspending a cooperative task. Don't replace it with `Task.sleep` or a GCD-based variant: the whole point is to survive cooperative-pool and libdispatch-QoS starvation.

### iOS simulator tests

- **`SimulatorManager.bootDevice` blocks until the device is actually booted.** `SBDevice.boot()` alone returns as soon as boot *starts*; `bootDevice` wraps it and then awaits `xcrun simctl bootstatus <udid> -b` (Apple's "block until SpringBoard is up" primitive). Callers can stop sleep-then-hoping. Default timeout is 180s — typical CI boot is 5-15s but P95 on busy GHA runners has been observed at 60-90s.
- **Display attach is async vs. bootstatus.** The display subsystem wires ports AFTER SpringBoard is up. On CI this race typically closes within 2-8s. `SimulatorManager.screenshotData` retries direct `SBCaptureFramebuffer` capture up to 5× with 2s backoff before falling back to `xcrun simctl io <udid> screenshot` (which has its own 60s timeout — it can hang indefinitely if the display never attaches).
- **Each sim-booting test resolves its own dedicated device via `SimulatorTestDevices` (#337).** Each test passes a distinct index and gets a harness-owned simulator named `previewsmcp-test-<index>`, created on demand as an iPhone 17 on the newest installed iOS 26+ runtime (idempotent; wrong-shape or duplicate devices with that name are deleted and recreated). This replaced the retired `IOSSimulatorPicker`, which indexed the shared `simctl` pool sorted by runtime and UDID — the index→model mapping was arbitrary per machine and reshuffled when an Xcode update changed the default device set. Resolve while holding `SimulatorTestLock` (creation mutates the shared device set); add a new index for any new iOS test that boots a device and record it in the `SimulatorTestDevices` doc comment.
- **iPhones only, not iPads.** The dedicated devices are pinned to iPhone 17. M-chip iPads (Air/Pro with M2+) on GHA runners have been observed exceeding 60s bootstatus — iPhones are reliable in the <15s window.
- **`AsyncProcessTimeout` carries pre-kill `capturedStdout` / `capturedStderr`.** When `runAsync(timeout:)` fires, the subprocess is SIGTERM'd and its pipes drained before the error is thrown, so CI logs show *which* stage the subprocess stalled at (e.g., `Waiting on <SpringBoard>`) rather than just "it hung."
- **CoreSimulator daemon state can still flake** after rapid boot/shutdown cycles — retry logic is built into `IOSPreviewSession.start()` for transient boot failures.
- The `bootAndShutdown` and `endToEnd` tests always clean up (shutdown device) even on failure.

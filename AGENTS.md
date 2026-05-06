# AGENTS.md

Project instructions for any AI coding agent (Claude Code, Codex, Cursor, Aider, …) working in this repo.

## Project

PreviewsMCP — standalone SwiftUI preview renderer with MCP server for AI-driven UI development. Renders `#Preview` blocks outside Xcode on both macOS and iOS simulator, with hot-reload, touch interaction, and accessibility tree inspection.

## Setup

```bash
brew bundle                              # Install tools (swift-format)
git config core.hooksPath .githooks      # Activate pre-commit formatting hook
swift build                              # Build all targets
```

Or run `/bootstrap` in Claude Code.

## Build & Test

```bash
swift build              # Build all targets
swift test               # Run all tests (~100+ tests, 12+ suites)
swift test --filter "PreviewParser"      # Run specific suite
swift test --filter "IOSHostBuilder"     # Test iOS host app compilation
swift test --filter "endToEnd"           # Full iOS pipeline (slow, boots simulator)
swift test --filter "VariantsCommandTests"       # CLI integration tests for a specific command
swift test --filter "MacOSMCPTests"              # MCP integration tests (real daemon)
```

Daemon-touching test suites use `DaemonTestLock` (flock) for cross-target serialization — `@Suite(.serialized)` only orders within a suite, not across test targets.

## Formatting & Linting

Swift sources are formatted with [swift-format](https://github.com/swiftlang/swift-format) (config: `.swift-format`) and linted with [SwiftLint](https://github.com/realm/SwiftLint) (config: `.swiftlint.yml`). The pre-commit hook runs both on staged files automatically.

```bash
swift-format format --in-place --recursive Sources/ Tests/ examples/   # Auto-fix formatting
swift-format lint --strict --recursive Sources/ Tests/ examples/        # Check formatting only
swiftlint lint --quiet Sources/ Tests/                                  # Semantic lint checks
```

SwiftLint complements swift-format: formatting rules are disabled (swift-format owns those), while SwiftLint catches semantic issues (cyclomatic complexity, function length, nesting depth, etc.).

## Architecture

```
Sources/
├── SimulatorBridge/     # ObjC — runtime-loads CoreSimulator.framework (no build-time linking)
├── PreviewsCore/        # Platform-agnostic: parser, compiler, bridge gen, differ, file watcher
├── PreviewsMacOS/       # macOS host: NSApplication + NSWindow + Snapshot (runs inside the daemon)
├── PreviewsIOS/         # iOS simulator: SimulatorManager, IOSHostBuilder, IOSPreviewSession
├── PreviewsCLI/         # CLI (ArgumentParser) + daemon + MCP server (swift-sdk)
└── PreviewsSetupKit/    # Setup plugin protocol (PreviewSetup) — zero-dependency SwiftUI-only library
```

- **PreviewsCore** has no platform-specific dependencies (no AppKit, no CoreSimulator)
- **SimulatorBridge** is ObjC because it uses `objc_lookUpClass` / protocol casts for private API access
- **PreviewsIOS** depends on SimulatorBridge; touch injection runs in-app via Hammer approach (IOHIDEvent + BKSHIDEventSetDigitizerInfo)
- **iOS host-app source lives in `HostAppSource/`** at the package root (`HostApp.swift`, `Info.plist`, `AppIcon.png`). The `EmbedHostAppSource` build-tool plugin (driven by `Sources/EmbedHostAppSourceTool/`) reads those files and emits `IOSHostAppSource.generated.swift` exposing them as `IOSHostAppSource.code` / `.infoPlist` / `IOSAppIconData.bytes` (base64-encoded). `IOSHostBuilder` writes the source out at session start and compiles it with swiftc targeting arm64-apple-ios-simulator. Byte-equivalence with the previous stringified blob is pinned by `IOSHostBuilderHashTests`.

### Daemon model

All CLI subcommands except `serve` are **daemon clients** — they connect to a background daemon process over a Unix domain socket at `~/.previewsmcp/serve.sock`. The daemon auto-starts on first CLI invocation (ADB-style) and persists across commands.

Key files:
- `DaemonClient.swift` — auto-start + connect via `withDaemonClient(name:body:)`. Registers a stderr log-forwarder for `LogMessageNotification` before the MCP handshake.
- `DaemonListener.swift` — `NWListener` on UDS, per-connection `MCP.Server`.
- `DaemonLifecycle.swift` — PID file, `setsid()` detachment, signal handlers.
- `DaemonProbe.swift` — socket liveness check (connect + immediate close).
- `SessionResolver.swift` — resolves `--session <uuid>` / `--file <path>` / sole-running-session targeting.
- `DaemonProtocol.swift` — shared `Codable` DTOs for `structuredContent` payloads on tool responses.
- `MCPContentHelpers.swift` — `Value.decode(_:)`, `Client.callToolStructured(...)`, `emitJSON(...)`.
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
- iOS host app source is real Swift in `HostAppSource/HostApp.swift` (lintable, formatable, compile-checked); the `EmbedHostAppSource` build-tool plugin embeds it as a base64 constant for runtime compilation with swiftc targeting arm64-apple-ios-simulator
- Old dylibs/views are retained (never dlclose) to prevent EXC_BAD_ACCESS
- `.tag()` integer literals are excluded from ThunkGenerator to avoid Int/CGFloat overload ambiguity
- All custom Error types must conform to `LocalizedError` with `errorDescription` (not just `CustomStringConvertible`) so MCP server reports useful messages

## MCP Server

Binary: `.build/debug/previewsmcp serve`
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

## Test Notes

### Test architecture

- **DaemonTestLock** serializes daemon-touching tests across suites via `flock`. Uses blocking `flock(LOCK_EX)` on `DispatchQueue.global` — NOT non-blocking polling with `Task.sleep`, which starves Swift's cooperative thread pool on CI runners with small pools (~3-4 threads) and causes deadlocks. The lock file path incorporates `PREVIEWSMCP_SOCKET_DIR` so concurrent CI jobs get separate locks.
- **`@Suite(.serialized)`** only orders tests within a single suite. It does NOT serialize across suites or test targets. DaemonTestLock exists to fill that gap.
- **`MCPTestServer.withTimeout`** races `body` against a detached `Thread` (pthread) timer, NOT a `Task.sleep`-based one. When the MCP SDK's transport loop busy-spins on a wedged server (see issue #135), the cooperative pool is starved and `Task.sleep`-based timers never fire — the prior `withThrowingTaskGroup` implementation silently timed out at Swift Testing's `.timeLimit` with no diagnostic. The pthread resumes a shared `CheckedContinuation` directly, which is a synchronous primitive with no pool dependency. On timeout the pthread also calls `process.terminate()` on the server subprocess so the daemon-side state doesn't persist into the next test. Note: the body `Task` may leak if its pending MCP continuation never drains (SDK transport EOF does not resume `pendingRequests`; only `disconnect()` does) — acceptable cost for an already-failing test; the process exits shortly after.
- All daemon-touching tests share one daemon at `~/.previewsmcp/serve.sock` (or `PREVIEWSMCP_SOCKET_DIR` if set). Each suite calls `cleanSlate()` at the start to kill any leftover daemon; the daemon auto-starts on the first CLI command and persists within the suite.

### CI-specific concerns

- **`build-and-test` and `ios-tests` run concurrently** on the same macOS runner. They MUST use different socket directories (`PREVIEWSMCP_SOCKET_DIR`) or they stomp on each other's daemon. Currently: `/tmp/previewsmcp-ci-build` and `/tmp/previewsmcp-ci-ios`.
- **iOS CLI tests are split across jobs**: macOS-only tests run in `build-and-test`, iOS-specific tests run in `ios-tests`. The iOS-specific CLI tests (`snapshotIOS` and `iosCLIWorkflow`) are skipped in `build-and-test` via `--skip` flags. `IOSCLIWorkflowTests` combines touch, elements, variants, and stop into a single workflow test to avoid paying daemon + simulator setup costs four times.
- **The daemon requires a window server** (`NSApplication.shared` + `NSHostingView` for rendering). GitHub Actions macOS runners have one, but the daemon must not be spawned in a context that loses display access (e.g., certain `launchd` contexts). If tests hang with zero output, check whether `CGMainDisplayID()` returns 0.
- **Daemon startup is slow on CI** (~5-10s vs ~500ms locally). The `DaemonClient.connect(startTimeout:)` default is 30s to accommodate this.
- **Daemon-global heartbeat** — the MCP server emits an unconditional `LogMessageNotification` with `logger: "heartbeat"` every 2s for the lifetime of a connected transport. Fires whether or not a tool call is in flight (necessary because the FileWatcher hot-reload path lives outside any request scope). `DaemonClient.registerStderrLogForwarder` filters these out of the CLI's stderr. See `runMCPServer` in `MCPServer.swift`. Do NOT replace `server.log(level:,logger:,data:)` with `ProgressNotification` — unsolicited progress notifications without a `progressToken` are out-of-spec.
- **Client-side stall detection** — every `DaemonClient.withDaemonClient` scope runs a `StallTimer` actor that bumps on any incoming notification (log or progress) and force-disconnects the transport if no activity arrives within 30s. Disconnect drains `pendingRequests` and resumes the body's `callTool` awaits with a transport error rather than hanging forever. Pairs with the heartbeat above — 30s threshold absorbs ~15 missed pings. Two subtleties: (1) the daemon's first heartbeat fires at T+2s after `server.start`, so `StallTimer` seeds `lastActivity` to `now` on connect (not 0); (2) heartbeats are `.debug` level, so `withDaemonClient` calls `client.setLoggingLevel(.debug)` during handshake — without this, MCP clients default to `.info` filtering and the heartbeat channel is dark.
- **MCPTestServer watchdog** — every active `MCPTestServer` spawns a detached `Thread` (real pthread) that wakes every 60s and writes the elapsed time plus the tail of the server's stderr to the test process's own stderr via `fputs`. Silent on the happy path (tests < 60s never emit), but when Swift Testing's `.timeLimit` kills a hanging MCP test the CI log contains a minute-by-minute trail of what the server subprocess was actually doing. The first implementation used `DispatchSource.makeTimerSource(qos: .utility)` — that produced no output in a real CI hang because libdispatch's utility-QoS workers were starved by whatever was burning cores. A raw pthread sidesteps QoS scheduling and Swift concurrency entirely; `Thread.sleep` blocks in the kernel rather than suspending a cooperative task. Don't replace it with `Task.sleep` or a GCD-based variant: the whole point is to survive cooperative-pool and libdispatch-QoS starvation.

### iOS simulator tests

- **`SimulatorManager.bootDevice` blocks until the device is actually booted.** `SBDevice.boot()` alone returns as soon as boot *starts*; `bootDevice` wraps it and then awaits `xcrun simctl bootstatus <udid> -b` (Apple's "block until SpringBoard is up" primitive). Callers can stop sleep-then-hoping. Default timeout is 180s — typical CI boot is 5-15s but P95 on busy GHA runners has been observed at 60-90s.
- **Display attach is async vs. bootstatus.** The display subsystem wires ports AFTER SpringBoard is up. On CI this race typically closes within 2-8s. `SimulatorManager.screenshotData` retries direct `SBCaptureFramebuffer` capture up to 5× with 2s backoff before falling back to `xcrun simctl io <udid> screenshot` (which has its own 60s timeout — it can hang indefinitely if the display never attaches).
- **Each iOS test picks a distinct simulator via `IOSSimulatorPicker`.** Three test suites (`SimulatorManagerTests`, `IOSPreviewSessionTests`, `IOSMCPTests`) boot simulators; Swift Testing runs them in parallel. Before the picker, all three selected "first available" from the same `xcrun simctl list` pool and stomped on each other (one shutting down what another was screenshotting). Now each test passes a distinct index (0, 1, 2) to `IOSSimulatorPicker.pick(index:)` / `pickUDID(index:)` and gets its own iPhone. Add a new index for any new iOS test that boots a device.
- **iPhone-class only, not iPads.** Picker filters by name contains "iPhone". M-chip iPads (Air/Pro with M2+) on GHA runners have been observed exceeding 60s bootstatus — iPhones are reliable in the <15s window.
- **`AsyncProcessTimeout` carries pre-kill `capturedStdout` / `capturedStderr`.** When `runAsync(timeout:)` fires, the subprocess is SIGTERM'd and its pipes drained before the error is thrown, so CI logs show *which* stage the subprocess stalled at (e.g., `Waiting on <SpringBoard>`) rather than just "it hung."
- **CoreSimulator daemon state can still flake** after rapid boot/shutdown cycles — retry logic is built into `IOSPreviewSession.start()` for transient boot failures.
- The `bootAndShutdown` and `endToEnd` tests always clean up (shutdown device) even on failure.

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
- **IOSHostAppSource.swift** contains the iOS host app as an embedded string, compiled at runtime by IOSHostBuilder

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
- iOS host app source is a string constant (like DesignTimeStore) — compiled with swiftc targeting arm64-apple-ios-simulator at runtime
- Old dylibs/views are retained (never dlclose) to prevent EXC_BAD_ACCESS
- `.tag()` integer literals are excluded from ThunkGenerator to avoid Int/CGFloat overload ambiguity
- All custom Error types must conform to `LocalizedError` with `errorDescription` (not just `CustomStringConvertible`) so MCP server reports useful messages

## MCP Server

Binary: `.build/debug/previewsmcp serve`
Config: `/.mcp.json` (in parent directory)

Tools: `preview_list`, `preview_start`, `preview_configure`, `preview_switch`, `preview_variants`, `preview_snapshot`, `preview_elements`, `preview_touch`, `preview_stop`, `simulator_list`, `session_list`

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

- **DaemonTestLock** serializes daemon-touching tests across suites via `flock`. Uses blocking `flock(LOCK_EX)` on `DispatchQueue.global` — NOT non-blocking polling with `Task.sleep`, which starves Swift's cooperative thread pool on CI runners with small pools (~3-4 threads) and causes deadlocks.
- **`@Suite(.serialized)`** only orders tests within a single suite. It does NOT serialize across suites or test targets. DaemonTestLock exists to fill that gap.
- All daemon-touching tests share one daemon at `~/.previewsmcp/serve.sock` (or `PREVIEWSMCP_SOCKET_DIR` if set). Each suite calls `cleanSlate()` at the start to kill any leftover daemon; the daemon auto-starts on the first CLI command and persists within the suite.

### CI-specific concerns

- **`build-and-test` and `ios-tests` run concurrently** on the same macOS runner. They MUST use different socket directories (`PREVIEWSMCP_SOCKET_DIR`) or they stomp on each other's daemon. Currently: `/tmp/previewsmcp-ci-build` and `/tmp/previewsmcp-ci-ios`.
- **iOS CLI tests are split across jobs**: macOS-only tests run in `build-and-test`, iOS-specific tests (`snapshotIOS`, `stopIOSSession`, `touchIOSHappyPath`, `capturesIOSVariants`, `elementsReturnsJSONTree`) run in `ios-tests`. Don't add new iOS tests without adding a corresponding `--skip` in `build-and-test`.
- **The daemon requires a window server** (`NSApplication.shared` + `NSHostingView` for rendering). GitHub Actions macOS runners have one, but the daemon must not be spawned in a context that loses display access (e.g., certain `launchd` contexts). If tests hang with zero output, check whether `CGMainDisplayID()` returns 0.
- **Daemon startup is slow on CI** (~5-10s vs ~500ms locally). The `DaemonClient.connect(startTimeout:)` default is 30s to accommodate this.

### iOS simulator tests

- Boot/shutdown real devices — can be slow (~10-20s)
- May flake from CoreSimulator daemon state after rapid boot/shutdown cycles — retry logic is built into IOSPreviewSession
- The `bootAndShutdown` and `endToEnd` tests always clean up (shutdown device) even on failure

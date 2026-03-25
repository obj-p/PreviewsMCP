# CLAUDE.md

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
swift test               # Run all tests (~34 tests, 7 suites)
swift test --filter "PreviewParser"      # Run specific suite
swift test --filter "IOSHostBuilder"     # Test iOS host app compilation
swift test --filter "endToEnd"           # Full iOS pipeline (slow, boots simulator)
```

## Formatting

Swift sources are formatted with [swift-format](https://github.com/swiftlang/swift-format) (config: `.swift-format`). The pre-commit hook lints staged files automatically.

```bash
swift-format format --in-place --recursive Sources/ Tests/ examples/   # Auto-fix
swift-format lint --strict --recursive Sources/ Tests/ examples/        # Check only
```

## Architecture

```
Sources/
├── SimulatorBridge/     # ObjC — runtime-loads CoreSimulator.framework (no build-time linking)
├── PreviewsCore/        # Platform-agnostic: parser, compiler, bridge gen, differ, file watcher
├── PreviewsMacOS/       # macOS host: NSApplication + NSWindow + Snapshot
├── PreviewsIOS/         # iOS simulator: SimulatorManager, IOSHostBuilder, IOSPreviewSession
└── PreviewsCLI/         # CLI (ArgumentParser) + MCP server (swift-sdk)
```

- **PreviewsCore** has no platform-specific dependencies (no AppKit, no CoreSimulator)
- **SimulatorBridge** is ObjC because it uses `objc_lookUpClass` / protocol casts for private API access
- **PreviewsIOS** depends on SimulatorBridge; touch injection runs in-app via Hammer approach (IOHIDEvent + BKSHIDEventSetDigitizerInfo)
- **IOSHostAppSource.swift** contains the iOS host app as an embedded string, compiled at runtime by IOSHostBuilder

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

Tools: `preview_list`, `preview_start`, `preview_configure`, `preview_switch`, `preview_variants`, `preview_snapshot`, `preview_elements`, `preview_touch`, `preview_stop`, `simulator_list`

## Trait Injection

`preview_configure` and `preview_start` accept `colorScheme` (`"light"` / `"dark"`) and `dynamicTypeSize` (e.g., `"large"`, `"accessibility3"`) to render previews under different SwiftUI traits. Traits are injected as `.preferredColorScheme()` and `.dynamicTypeSize()` modifiers in the generated bridge code. Changing traits triggers a full recompile (@State is lost). Traits persist across hot-reload cycles and preview switches.

## Multi-Preview Support

Files with multiple `#Preview` blocks are fully supported. `preview_list` shows all previews with closure body snippets. `preview_start` accepts a `previewIndex` parameter (default 0) and returns the full list of available previews. `preview_switch` changes which preview is rendered in a running session without tearing down the session — traits persist across switches, @State is reset. If a switch fails (e.g., invalid index), the session rolls back to the previous preview.

**macOS limitation:** `dynamicTypeSize` has no visible effect on macOS. macOS does not have a system-level Dynamic Type feature, and `NSHostingView` does not scale fonts in response to the `.dynamicTypeSize()` modifier. Use iOS simulator previews to test dynamic type sizes. `colorScheme` works on both platforms.

## Variant Capture

`preview_variants` captures screenshots under multiple trait configurations in a single MCP call. Pass preset names (`"light"`, `"dark"`, `"xSmall"` through `"accessibility5"`) or JSON object strings for custom combinations (e.g., `{"colorScheme":"dark","dynamicTypeSize":"large","label":"dark+large"}`). The session's original traits are restored after all variants are captured. Each variant triggers a recompile.

## iOS Touch Injection

Uses Hammer approach (in-app, headless, no mouse movement):
1. IOKit: `IOHIDEventCreateDigitizerFingerEvent` (transducerType=3)
2. BackBoardServices: `BKSHIDEventSetDigitizerInfo` with `UIWindow._contextId`
3. UIKit: `UIApplication._enqueueHIDEvent:`

All loaded via dlopen/dlsym inside the iOS host app. Does NOT use IndigoHID/SimulatorKit (those create pointer events, not touch events on Xcode 26.2).

## Test Notes

- iOS simulator tests boot/shutdown real devices — can be slow (~10-20s)
- Tests that use simulators may flake from CoreSimulator daemon state after rapid boot/shutdown cycles — retry logic is built into IOSPreviewSession
- The `bootAndShutdown` and `endToEnd` tests always clean up (shutdown device) even on failure

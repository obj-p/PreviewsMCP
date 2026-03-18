# PreviewsMCP

Render and interact with SwiftUI previews outside of Xcode. Works as a CLI tool and as an [MCP server](https://modelcontextprotocol.io/) for AI-driven UI development.

## Features

- **Render `#Preview` blocks** on macOS and iOS simulator without Xcode
- **Hot-reload** — edit source files and see changes instantly (literal-only changes preserve `@State`)
- **iOS simulator** — boot, install, launch, screenshot, and interact with previews headlessly
- **Touch injection** — tap and swipe gestures on iOS simulator (headless, no mouse cursor movement)
- **Accessibility tree** — inspect view hierarchy with labels, frames, and traits for targeted interaction
- **MCP server** — 7 tools for AI agents to render, inspect, and interact with SwiftUI views

## Installation

### From source

```bash
git clone https://github.com/obj-p/PreviewsMCP.git
cd PreviewsMCP
swift build -c release
```

The binary is at `.build/release/previewsmcp`.

### Requirements

- macOS 14+
- Xcode 16+ (for iOS simulator support)
- Apple Silicon

## CLI Usage

```bash
# List #Preview blocks in a file
previewsmcp list MyView.swift

# Run a live preview window (macOS)
previewsmcp run MyView.swift

# Capture a screenshot
previewsmcp snapshot MyView.swift -o preview.png

# Start the MCP server
previewsmcp serve
```

## MCP Server Setup

Add to your `.mcp.json` (or Claude Code MCP config):

```json
{
  "mcpServers": {
    "previews": {
      "command": "/path/to/previewsmcp",
      "args": ["serve"]
    }
  }
}
```

### Available Tools

| Tool | Description |
|------|-------------|
| `preview_list` | List `#Preview` blocks in a Swift source file |
| `preview_start` | Compile and launch a preview (macOS or iOS simulator) |
| `preview_snapshot` | Capture a screenshot of a running preview |
| `preview_elements` | Get the accessibility tree (labels, frames, traits) |
| `preview_touch` | Send tap or swipe gestures to iOS simulator |
| `preview_stop` | Close a preview session |
| `simulator_list` | List available iOS simulator devices |

### Example: iOS Simulator Preview

```
1. simulator_list                              → find available devices
2. preview_start(filePath, platform: "ios-simulator")  → boot sim, compile, launch
3. preview_elements(sessionID)                 → find button coordinates
4. preview_snapshot(sessionID)                  → capture screenshot
5. preview_touch(sessionID, x, y)              → tap a button
6. preview_touch(sessionID, x, y, action: "swipe", toX, toY)  → swipe gesture
7. preview_stop(sessionID)                     → clean up
```

## Architecture

```
Sources/
├── SimulatorBridge/     ObjC bridge to CoreSimulator.framework
├── PreviewsCore/        Parser, compiler, bridge generator, literal differ
├── PreviewsMacOS/       macOS NSWindow host + screenshot capture
├── PreviewsIOS/         iOS simulator manager, host app builder, touch injection
└── PreviewsCLI/         CLI + MCP server
```

The iOS host app (`PreviewsMCPHost`) is compiled at runtime targeting the iOS simulator SDK. It loads preview dylibs via `dlopen` and renders views through `UIHostingController`. Touch injection uses the [Hammer](https://github.com/lyft/Hammer) approach — `IOHIDEvent` creation via IOKit + `BKSHIDEventSetDigitizerInfo` from BackBoardServices + delivery through `UIApplication._enqueueHIDEvent:`.

See [`docs/reverse-engineering.md`](docs/reverse-engineering.md) for detailed investigation notes on the iOS simulator HID protocol, IndigoHID message format, and Xcode's preview architecture.

## Development

```bash
swift build          # Build
swift test           # Run all tests (~34 tests, 7 suites)
```

See [`CLAUDE.md`](CLAUDE.md) for detailed development context.

## License

MIT

<p align="center">
  <img src="assets/icon.svg" width="128" height="128" alt="PreviewsMCP icon">
</p>

<h1 align="center">PreviewsMCP</h1>

<p align="center">
  A standalone SwiftUI preview host for humans and AI agents.<br>
  Run, snapshot, and interact with <code>#Preview</code> blocks from the command line or over <a href="https://modelcontextprotocol.io/">MCP</a> — no Xcode process required.
</p>

<p align="center">
  <img src="assets/demo.gif" alt="PreviewsMCP iOS hot-reload demo" width="900">
</p>

<p align="center"><em>Edit the source, the simulator hot-reloads live.</em></p>

## Quickstart

```bash
git clone https://github.com/obj-p/PreviewsMCP.git
cd PreviewsMCP
swift run previewsmcp examples/spm/Sources/ToDo/ToDoView.swift
```

A live macOS preview window opens. Edit the source file and the window hot-reloads.

## Installation

### Homebrew

```bash
brew tap obj-p/tap
brew install previewsmcp
```

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

## Capabilities

- **Live previews** — hot-reload SwiftUI on macOS (`NSHostingView`) or a real iOS simulator, preserving `@State` where it can.
- **Variant & trait sweeps** — render one preview across many trait combinations (`colorScheme`, `dynamicTypeSize`, `locale`, `layoutDirection`, `legibilityWeight`) in a single call, with presets for light/dark, `xSmall`–`accessibility5`, `rtl`, `ltr`, and `boldText`.
- **Multi-preview selection** — `#Preview` macros and legacy `PreviewProvider`, with mid-session switching.
- **iOS interaction** — walk the accessibility tree and inject taps/swipes through an in-simulator touch bridge.
- **Setup plugin + project config** — `.previewsmcp.json` for per-project defaults and a zero-dependency [`PreviewSetup`](Sources/PreviewsSetupKit/PreviewSetup.swift) protocol for mock DI, fonts, and themes.

## Usage

### CLI

```bash
previewsmcp help                   # top-level overview
previewsmcp help <subcommand>      # full options for run / snapshot / variants / list / serve
```

A few common invocations:

```bash
previewsmcp MyView.swift                           # live macOS preview window
previewsmcp MyView.swift --platform ios            # iOS simulator
previewsmcp snapshot MyView.swift -o preview.png   # one-shot screenshot
previewsmcp list MyView.swift                      # enumerate #Preview blocks
```

Drop a `.previewsmcp.json` at your project root to set defaults for every CLI command and MCP tool call (see [`examples/.previewsmcp.json`](examples/.previewsmcp.json) for the canonical shape):

```json
{
  "platform": "ios",
  "device": "iPhone 16 Pro",
  "traits": { "colorScheme": "dark", "locale": "en" }
}
```

Explicit CLI/MCP parameters override config values. The config is auto-discovered by walking up from the source file directory.

### MCP server

Add to your agent's MCP config — same `mcpServers` shape whether it lands in `.mcp.json` (Claude Code), `~/.cursor/mcp.json` (Cursor), `.vscode/mcp.json` (VS Code), or `claude_desktop_config.json` (Claude Desktop):

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

Once connected, ask your agent *"what `previews` tools are available?"* — it will describe them directly from the server's registered schemas, including snapshotting, variant capture, accessibility-tree inspection, and touch injection.

## Why / why not

**Use PreviewsMCP when** you want scriptable SwiftUI rendering from a CI job, a shell, or an AI agent — anywhere the Xcode canvas isn't convenient. It's particularly useful for trait sweeps (localization, dynamic type, RTL) and for agents driving visual feedback loops.

**Use Xcode previews when** you need full canvas fidelity: device chrome, orientation, `@PreviewModifier`, and `previewLayout` customization. PreviewsMCP is a headless renderer, not a canvas replacement.

**Known limitation:** `dynamicTypeSize` is a no-op on macOS — `NSHostingView` doesn't scale fonts in response to the modifier. Use the iOS simulator path to test Dynamic Type.

## Further reading

- [`docs/architecture.md`](docs/architecture.md) — pipeline diagram, module layout, and the private-framework surface used for iOS rendering.
- [`docs/build-system-integration.md`](docs/build-system-integration.md) — how SPM / Xcode / Bazel projects are detected and built.
- [`examples/`](examples/) — working SPM, Xcode, and Bazel projects, plus a canonical `PreviewSetup` example.

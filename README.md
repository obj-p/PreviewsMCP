<p align="center">
  <img src="assets/icon.svg" width="128" height="128" alt="PreviewsMCP icon">
</p>

<h1 align="center">PreviewsMCP</h1>

<p align="center">
  Render and interact with SwiftUI previews outside of Xcode.<br>
  Works as a CLI tool and as an <a href="https://modelcontextprotocol.io/">MCP server</a> for AI-driven UI development.
</p>

<p align="center">
  <img src="assets/demo.gif" alt="PreviewsMCP iOS hot-reload demo" width="900">
</p>

<p align="center"><em>Edit a SwiftUI source file — the iOS simulator hot-reloads live. No Xcode.</em></p>

<p align="center">
  <img src="assets/preview-light.png" alt="Light variant" width="260">
  &nbsp;
  <img src="assets/preview-dark.png" alt="Dark variant" width="260">
</p>


## How it works

```mermaid
flowchart LR
    Agent([AI Agent]) -->|MCP tools| Server[previewsmcp serve]
    Server --> Parse[Parse #Preview]
    Parse --> Compile[Compile bridge dylib]
    Compile --> Platform{Platform}
    Platform -->|macOS| Mac[NSHostingView]
    Platform -->|iOS| Sim[Simulator + host app]
    Mac --> Capture[Snapshot &middot; a11y tree &middot; touch]
    Sim --> Capture
    Capture -->|image, elements| Agent
    Agent -.->|edit .swift| Watch[File watcher]
    Watch -.->|hot reload| Compile
```

The agent drives the loop: call an MCP tool, get a snapshot or accessibility tree back, edit code, and the file watcher triggers a hot reload that preserves `@State` where possible. No Xcode needed.

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

## CLI Usage

```bash
# List previews in a file (#Preview macros and PreviewProvider)
previewsmcp list MyView.swift

# Run a live preview window (macOS)
previewsmcp run MyView.swift

# Run a specific preview (0-based index)
previewsmcp run MyView.swift --preview 1

# Run on iOS simulator (Simulator.app window visible by default)
previewsmcp run MyView.swift --platform ios

# Run iOS preview headless (hide Simulator.app GUI)
previewsmcp run MyView.swift --platform ios --headless

# Specify project root for Xcode/Bazel projects
previewsmcp run MyView.swift --project ./MyApp

# Render with trait overrides
previewsmcp run MyView.swift --color-scheme dark --dynamic-type-size accessibility3

# Capture a screenshot (JPEG by default, .png for PNG)
previewsmcp snapshot MyView.swift -o preview.png

# Snapshot a specific preview with traits
previewsmcp snapshot MyView.swift --preview 1 --color-scheme dark -o dark.jpg

# Snapshot on iOS simulator
previewsmcp snapshot MyView.swift --platform ios -o ios_preview.png

# Capture multiple trait variants in one run (creates one image per variant)
previewsmcp variants MyView.swift --variant light --variant dark -o snapshots/

# Custom variants with JSON object strings (label sets the output filename)
previewsmcp variants MyView.swift \
  --variant '{"colorScheme":"dark","dynamicTypeSize":"large","label":"dark-large"}' \
  --variant '{"colorScheme":"light","dynamicTypeSize":"xSmall","label":"light-xSmall"}' \
  --platform ios -o snapshots/
```

Supports both `#Preview` macros and the legacy `PreviewProvider` protocol — `list` shows all previews from both, and `run`/`snapshot` can render any by index.

## MCP Server

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

### Tools

| Tool | Description |
|---|---|
| `preview_list` | List `#Preview` blocks and `PreviewProvider` previews in a Swift file |
| `preview_start` | Compile and launch a live preview (macOS or iOS simulator). Returns a session ID |
| `preview_snapshot` | Capture a screenshot of the active session (JPEG by default; `quality: 1.0` for PNG) |
| `preview_configure` | Update traits (`colorScheme`, `dynamicTypeSize`) on a running session |
| `preview_switch` | Swap to a different `#Preview` index without tearing down the session |
| `preview_variants` | Capture screenshots under multiple trait configurations in one call |
| `preview_elements` | Inspect the accessibility tree of an iOS preview |
| `preview_touch` | Send a tap or swipe to an iOS preview |
| `preview_stop` | Close a session |
| `simulator_list` | List available iOS simulator devices |

### Capturing variants

`preview_variants` captures multiple snapshots in a single call — useful for comparing light/dark mode, dynamic type sizes, or custom trait combinations. Each variant triggers a recompile, and the session's original traits are restored afterward.

Pass an array of preset names or JSON object strings as the `variants` argument:

```jsonc
// Preset names — light/dark and xSmall through accessibility5
{
  "sessionID": "...",
  "variants": ["light", "dark", "accessibility3"]
}

// Custom combinations via JSON object strings
{
  "sessionID": "...",
  "variants": [
    "{\"colorScheme\":\"dark\",\"dynamicTypeSize\":\"large\",\"label\":\"dark+large\"}",
    "{\"colorScheme\":\"light\",\"dynamicTypeSize\":\"xSmall\",\"label\":\"light+xSmall\"}"
  ]
}
```

The response contains one labeled image per variant.

## Regenerating the demo assets

Two pipelines produce the README visuals:

```bash
brew install vhs ffmpeg

# Side-by-side iOS hot-reload demo (assets/demo.gif):
# records the terminal via vhs and the booted simulator via `simctl io
# recordVideo` in parallel, then composites them with ffmpeg.
scripts/record-demo-ios.sh

# Terminal-only demo + light/dark variant PNGs:
# uses previewsmcp variants against the bundled SPM ToDo example and
# copies the captured PNGs into assets/.
scripts/record-demo.sh
```

Each script builds `previewsmcp` if needed, runs against the bundled SPM `ToDo` example, and writes outputs to `assets/`.

# PreviewsMCP

Render and interact with SwiftUI previews outside of Xcode. Works as a CLI tool and as an [MCP server](https://modelcontextprotocol.io/) for AI-driven UI development.

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

# Run on iOS simulator (headless by default)
previewsmcp run MyView.swift --platform ios

# Run with a visible Simulator.app window
previewsmcp run MyView.swift --platform ios --no-headless

# Specify project root for Xcode/Bazel projects
previewsmcp run MyView.swift --project ./MyApp

# Render with trait overrides
previewsmcp run MyView.swift --color-scheme dark --dynamic-type-size accessibility3

# Capture a screenshot (JPEG by default, .png for PNG)
previewsmcp snapshot MyView.swift -o preview.png

# Snapshot a specific preview with traits
previewsmcp snapshot MyView.swift --preview 1 --color-scheme light -o dark.jpg

# Snapshot on iOS simulator
previewsmcp snapshot MyView.swift --platform ios -o ios_preview.png
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

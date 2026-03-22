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
# List #Preview blocks in a file
previewsmcp list MyView.swift

# Run a live preview window (macOS)
previewsmcp run MyView.swift

# Run on iOS simulator
previewsmcp run MyView.swift --platform ios-simulator

# Capture a screenshot
previewsmcp snapshot MyView.swift -o preview.png

# Open a playground — creates a temp file with a starter view and live-reloads on edit
previewsmcp playground
previewsmcp playground --platform ios-simulator

# Or use an existing file
previewsmcp playground MyView.swift

# Pipe to your editor
vim $(previewsmcp playground)
```

The `playground` command opens a live preview with hot-reload — no project setup needed. Pass an existing file or omit to create a temp one.

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

Tools: `preview_list`, `preview_start`, `preview_snapshot`, `preview_elements`, `preview_touch`, `preview_stop`, `preview_playground`, `simulator_list`

## License

MIT

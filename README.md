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

# Capture a screenshot
previewsmcp snapshot MyView.swift -o preview.png

# Start the MCP server
previewsmcp serve
```

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

## License

MIT

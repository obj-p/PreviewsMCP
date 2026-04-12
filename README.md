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

Parse the target `.swift` file, compile a bridge dylib, render it in an `NSHostingView` or a booted iOS simulator, and hand snapshots or the accessibility tree back to whoever asked. A file watcher hot-reloads edits in place, preserving `@State` where it can. Both `#Preview` macros and legacy `PreviewProvider` types are supported.

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

### MCP server

Add to your agent's MCP config (`.mcp.json`, Claude Code, Cursor, etc.):

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

# iOS Preview Communication Protocol

PreviewsMCP's CLI and iOS simulator host app communicate over a TCP loopback socket. This document describes the protocol design and the reasoning behind it.

## Architecture

```
┌──────────────────┐         TCP 127.0.0.1:port        ┌──────────────────┐
│  CLI / MCP Server│◄──────────────────────────────────►│  iOS Host App    │
│  (macOS process) │         newline-delimited JSON     │  (simulator)     │
└──────────────────┘                                    └──────────────────┘
         │                                                       │
         │ creates socket, binds, listens                        │ connects on launch
         │ accepts after app launch                              │ reads via DispatchSource
         │ writes commands, reads responses                      │ dispatches to main queue
```

The CLI acts as the TCP server. The host app connects as a client on launch. One connection per session.

## Why TCP loopback

We evaluated three approaches:

### File polling (previous approach)
The original implementation used 6 temp files polled by 4 independent Timers in the host app (100-300ms intervals). Problems:
- **Latency**: 100-300ms polling delay on every interaction
- **Resource waste**: 4 timers firing constantly even when idle
- **No cleanup**: 140+ session directories accumulating in /tmp (~63MB)
- **Fragile ack mechanism**: reload acknowledgment required polling a separate ack file

### Unix domain sockets
UDS would provide instant delivery and proper lifecycle, but the iOS simulator may resolve `sockaddr_un` paths against the simulated filesystem rather than the macOS host filesystem. While the simulator transparently maps host paths for file I/O (the host app reads dylibs via absolute host paths), socket `connect()` path resolution is kernel-level and may not follow the same mapping. This makes UDS unreliable for cross-boundary communication.

### TCP loopback (chosen)
`127.0.0.1` is guaranteed to work — the iOS simulator shares the host's network stack. Additional benefits:
- No path length limits (`sun_path` is only 104 bytes)
- No `sockaddr_un` struct casting (simpler code, especially in the string-embedded host app)
- Ephemeral port binding avoids conflicts
- Standard networking — easy to debug with tools like `netcat`

### Why not Xcode's approach
Xcode Preview passes a Unix domain socket fd to `XCPreviewAgent` via `posix_spawn` fd inheritance. We can't do this because the host app is launched via `simctl launch`, which delegates to the CoreSimulator daemon — no fd inheritance is possible.

## Message format

Newline-delimited JSON. Each message is a single JSON object followed by `\n` (0x0A).

```
{"type":"reload","id":"abc123","dylibPath":"/tmp/previewsmcp/.../Preview_1.dylib"}\n
```

### Fields

- `type` (string, required): Message type identifier
- `id` (string, optional): Request ID for matching responses. Present on request/response messages, absent on fire-and-forget messages.

## Message types

### `reload` (CLI → Host, request/response)

Tells the host app to load a newly compiled dylib.

```json
{"type": "reload", "id": "abc123", "dylibPath": "/path/to/Preview_1.dylib"}
```

The host app calls `dlopen()` on the dylib, extracts `createPreviewView`, and sets the new view controller as `rootViewController`. After one RunLoop turn (to allow SwiftUI environment propagation), it sends:

```json
{"type": "reloadAck", "id": "abc123"}
```

The extra `DispatchQueue.main.async` before sending the ack ensures that `.dynamicTypeSize()` and other SwiftUI environment modifiers have propagated through the `UIHostingController`. Without this, rapid successive reloads can cause `dynamicTypeSize` to visually drop while `preferredColorScheme` (which maps to UIKit's `overrideUserInterfaceStyle`) works immediately.

### `literals` (CLI → Host, fire-and-forget)

Sends literal value updates for the hot-reload fast path (state-preserving).

```json
{"type": "literals", "changes": [
  {"id": "design_1", "type": "string", "value": "Updated text"},
  {"id": "design_2", "type": "integer", "value": 42},
  {"id": "design_3", "type": "float", "value": 3.14},
  {"id": "design_4", "type": "boolean", "value": true}
]}
```

The host app calls `dlsym` to find `designTimeSetString`/`designTimeSetInteger`/etc. and updates values in the running `DesignTimeStore`. No response is sent — the update is immediate and state-preserving.

### `touch` (CLI → Host, fire-and-forget)

Injects touch events via the Hammer approach (IOHIDEvent + BKSHIDEventSetDigitizerInfo).

Tap:
```json
{"type": "touch", "action": "tap", "x": 200.0, "y": 400.0}
```

Swipe:
```json
{"type": "touch", "action": "swipe", "fromX": 200, "fromY": 300, "toX": 50, "toY": 300, "duration": 0.3, "steps": 10}
```

No response is sent. The CLI waits a fixed duration after sending (250ms for tap, duration+200ms for swipe) to allow the UI to settle before taking screenshots.

### `elements` (CLI → Host, request/response)

Requests the accessibility tree for element inspection.

```json
{"type": "elements", "id": "def456", "filter": "interactable"}
```

The host app walks the accessibility tree starting from the window and sends:

```json
{"type": "elementsResponse", "id": "def456", "tree": {"role": "group", "children": [...]}}
```

The `filter` parameter is passed through but filtering is applied on the CLI side after receiving the full tree. Valid values: `"all"`, `"interactable"`, `"labeled"`.

## Connection lifecycle

1. **CLI binds** to `127.0.0.1:0` (ephemeral port) and calls `listen()`
2. **CLI launches** the host app via `simctl launch` with `--port <port>`
3. **Host app connects** to `127.0.0.1:<port>` on launch
4. **CLI accepts** the connection (up to 10 second timeout)
5. **Both sides** set up `DispatchSource.makeReadSource` for non-blocking reads
6. **Communication** flows bidirectionally over the single connection
7. **On `preview_stop`**: CLI calls `stop()` which closes fds and cancels read sources
8. **On host crash**: CLI's read source fires with `read() == 0` (EOF), pending continuations fail with `connectionLost`

## Error handling

- **Accept timeout**: If the host app doesn't connect within 10 seconds, `socketAcceptTimeout` is thrown
- **Response timeout**: `reload` and `elements` requests time out after 5s and 3s respectively
- **Disconnect**: Any pending request/response continuations are failed with `connectionLost`
- **Timeout safety**: Timeouts use a racing `Task.sleep` pattern. The continuation is removed from `pendingDataResponses` by whichever side fires first (response arrival or timeout), preventing double-resume

### `previewSetUp` (Host internal, not a message)

On the first `reload`, the host app checks for a `previewSetUp` symbol in the dylib via `dlsym`. If found, it calls it once and sets a `hasCalledSetUp` flag. Subsequent reloads skip this step entirely — `setUp()` side effects (registered fonts, auth tokens, SDK init) persist in the host process.

The `previewSetUp` function is generated by `BridgeGenerator` when a setup plugin is configured. It bridges async `setUp()` via `Task` + `DispatchSemaphore`. Errors are currently swallowed with `try?` inside the generated code.

## Screenshots

Screenshots are NOT sent over the socket. They're captured via `SimulatorManager` using either IOSurface (direct framebuffer) or `simctl io screenshot` (fallback). This keeps the socket protocol simple and avoids sending large binary payloads over a text-based protocol.

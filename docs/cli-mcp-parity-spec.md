# Spec: CLI/MCP Parity via Daemon

**Status:** Draft
**Related issues:** [#92](https://github.com/obj-p/PreviewsMCP/issues/92), [#94](https://github.com/obj-p/PreviewsMCP/issues/94), [#95](https://github.com/obj-p/PreviewsMCP/issues/95) (deferred)

## Objective

Close the CLI/MCP capability gap so every MCP tool has a CLI equivalent. Today the CLI is positioned as the primary interface, but the MCP server is a strict superset: six capabilities (`preview_snapshot`, `preview_configure`, `preview_switch`, `preview_elements`, `preview_touch`, `simulator_list`) exist only over MCP. A user running `previewsmcp run` cannot snapshot, reconfigure, switch previews, inspect elements, inject touches, or list simulators mid-session from the CLI.

**Approach:** CLI becomes a thin client over the existing MCP server. A long-lived daemon (`previewsmcp serve --daemon`) multiplexes all sessions; CLI commands speak MCP JSON-RPC to it over a Unix domain socket. One implementation, one protocol.

**Primary users:** developers using the CLI for local dev, scripting, and CI. Indirect beneficiaries: agents driving the MCP server — they get a more testable reference implementation because the CLI exercises the same code paths.

**Success:** every MCP tool has a CLI command. Ship each command as its own validated PR, stacked.

## Architecture

### Daemon model (ADB-style)

One `previewsmcp serve --daemon` process manages N concurrent preview sessions (each a window on macOS or simulator host on iOS). CLI commands are JSON-RPC clients targeting a Unix domain socket at `~/.previewsmcp/serve.sock`. First CLI invocation auto-starts the daemon if not running, ADB-style. No port conflicts (filesystem-scoped permissions instead).

```
┌──────────────────────────┐
│ previewsmcp snapshot ... │   CLI client (short-lived)
└──────────────┬───────────┘
               │ MCP JSON-RPC
               ▼
    ~/.previewsmcp/serve.sock
               │
               ▼
┌──────────────────────────┐
│ previewsmcp serve        │   Daemon (long-lived)
│   - PreviewHost (macOS)  │   - owns NSApplication + windows
│   - IOSState             │   - manages N sessions
│   - Compiler (shared)    │
│   - ConfigCache          │
└──────────────────────────┘
```

### Session state

Sessions live in the daemon's memory. No per-session files. Discovery via RPC:

- `session/list` — enumerate all active sessions
- `session/findByFile {path}` — resolve source file to session UUID (errors on ambiguity)
- `session/latest` — most recently created session

### Filesystem footprint

```
~/.previewsmcp/
  serve.sock     # daemon Unix socket (primary IPC)
  serve.pid      # daemon PID (for kill-daemon / status UX only)
  serve.log      # daemon logs
```

No per-session files. Minimal, single-source-of-truth.

### Liveness check

CLI commands check daemon liveness by `connect(~/.previewsmcp/serve.sock)`. Success → RPC. Failure (`ENOENT`/`ECONNREFUSED`) → auto-start daemon (fork+exec `serve --daemon`), poll socket for ~2s, then RPC. Daemon startup unlinks any stale socket file before `bind()`.

### Transport

Existing `MCPServer.swift` (`configureMCPServer()`) is already transport-agnostic — it builds handlers on an `MCP.Server`. Today's stdio flow:

```swift
let (server, _) = try await configureMCPServer()
try await server.start(transport: StdioTransport())
```

For the daemon, reuse the same handler setup with a different transport — likely `NetworkTransport` over `NWEndpoint.unix(path:)`. One `Server` instance per accepted connection; shared state (IOSState, ConfigCache, Compiler) is held in module-level actors.

Small refactor: `Compiler` is currently per-call in `configureMCPServer()`. Make it shared across connections.

### Session resolution UX

All session-scoped CLI commands accept:

- `--session <uuid>` — explicit
- `--file <path>` — resolves source file → session
- No flag → use the sole session if exactly one exists; error otherwise with a clear message listing active sessions

## Commands

Existing (modified):

```bash
previewsmcp run <file>              # attached, Ctrl+C stops session (Docker-style)
previewsmcp run <file> --detach     # detached, returns session ID, daemon keeps running
previewsmcp snapshot [<file>]       # magical: reuse live session if present, else ephemeral
previewsmcp variants <file> ...     # migrates to daemon (existing command)
```

New (session-scoped):

```bash
previewsmcp configure [--session X | --file Y] --color-scheme dark ...
previewsmcp switch [--session X | --file Y] <preview-index>
previewsmcp elements [--session X | --file Y]
previewsmcp touch [--session X | --file Y] <x> <y> [--action swipe --to-x N --to-y M]
previewsmcp stop [--session X | --file Y]
```

New (static / daemon management):

```bash
previewsmcp simulators                # list available simulators (static, no session)
previewsmcp serve --daemon            # start daemon (idempotent)
previewsmcp serve --foreground        # run daemon attached (debug)
previewsmcp status                    # "daemon running (pid X), N sessions"
previewsmcp kill-daemon               # graceful SIGTERM
```

Existing `previewsmcp serve` (MCP-over-stdio for Claude/IDE) stays unchanged.

## Project Structure

New sources:

```
Sources/PreviewsCLI/
  DaemonCommand.swift              # serve --daemon, status, kill-daemon
  DaemonClient.swift               # JSON-RPC client wrapper (auto-start + connect)
  UnixSocketTransport.swift        # MCP Transport conformance over NWConnection.unix
  SessionResolver.swift            # --session / --file / latest resolution
  ConfigureCommand.swift           # new
  SwitchCommand.swift              # new
  ElementsCommand.swift            # new
  TouchCommand.swift               # new
  StopCommand.swift                # new
  SimulatorsCommand.swift          # new
```

Modified:

```
Sources/PreviewsCLI/
  ServeCommand.swift               # add --daemon flag
  RunCommand.swift                 # migrate to DaemonClient, add --detach
  SnapshotCommand.swift            # magical reuse via DaemonClient
  VariantsCommand.swift            # migrate to DaemonClient
  MCPServer.swift                  # share Compiler across connections (small refactor)
```

Tests:

```
Tests/CLIIntegrationTests/
  DaemonLifecycleTests.swift       # auto-start, liveness, kill-daemon, stale socket
  SessionResolverTests.swift       # --session / --file / latest semantics
  ConfigureCommandTests.swift      # per-command integration tests
  SwitchCommandTests.swift
  ElementsCommandTests.swift
  TouchCommandTests.swift
  StopCommandTests.swift
  SimulatorsCommandTests.swift
```

## Code Style

Match existing patterns in `Sources/PreviewsCLI/`. Example (new command skeleton):

```swift
import ArgumentParser
import Foundation
import MCP
import PreviewsCore

struct ConfigureCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "configure",
        abstract: "Reconfigure traits on a running preview session"
    )

    @Option(name: .long, help: "Session UUID (defaults to sole running session)")
    var session: String?

    @Option(name: .long, help: "Resolve session by source file path")
    var file: String?

    @Option(name: .long, help: "Color scheme: 'light' or 'dark'")
    var colorScheme: String?

    // ...other trait flags mirror MCP preview_configure parameters

    mutating func run() async throws {
        let client = try await DaemonClient.connect()
        let sessionID = try await SessionResolver.resolve(
            session: session, file: file, client: client
        )
        _ = try await client.call("preview_configure", arguments: [
            "sessionID": .string(sessionID),
            // ...trait args
        ])
    }
}
```

Key conventions:
- Use `AsyncParsableCommand` (already used by some commands).
- `DaemonClient.connect()` handles auto-start + connect + version check.
- `SessionResolver.resolve()` centralizes the `--session` / `--file` / sole-session logic.
- CLI output goes to stdout; progress/errors to stderr.
- Errors surface MCP error codes with human-readable `message` fields.

## Testing Strategy

**Framework:** swift-testing (`@Test`, `#expect`), matching existing tests.

**Layers:**
- **Unit tests** (`Tests/PreviewsCoreTests/`) — for new non-CLI logic (e.g., `SessionResolver` pure functions, transport framing).
- **Integration tests** (`Tests/CLIIntegrationTests/`) — spawn the real `previewsmcp` binary, assert behavior end-to-end. Each new command gets its own file.
- **Daemon lifecycle tests** — auto-start, stale socket cleanup, graceful shutdown, crash recovery.

**Per-command integration test must cover:**
- Happy path with `--session`
- Happy path with `--file`
- Sole-session default path
- Error on zero sessions
- Error on multiple sessions (ambiguous resolution)
- Error on nonexistent session ID

**Existing tests that must still pass unchanged:** all `MCPIntegrationTests` (stdio MCP server still works for Claude).

## Boundaries

**Always:**
- Run `swift test --filter "PreviewsCoreTests"` and `swift test --filter "CLIIntegrationTests"` before committing.
- Preserve existing `previewsmcp serve` stdio behavior (don't break Claude integration).
- Share state between connections via existing module-level actors (`IOSState`, `ConfigCache`); don't introduce per-connection state that should be shared.
- Clean up stale `~/.previewsmcp/serve.sock` before `bind()` in daemon startup.

**Ask first:**
- Any change to MCP JSON-RPC tool names or parameter schemas (would break Claude integration).
- New filesystem locations outside `~/.previewsmcp/`.
- Changes to `MCPServer.swift` beyond sharing `Compiler`.
- Protocol changes between host app and daemon (would affect iOS touch/elements).

**Never:**
- Reimplement MCP dispatch in a parallel codepath.
- Use TCP loopback instead of Unix socket.
- Persist session state to disk (in-memory only; ephemeral by design).
- Kill the daemon from a CLI command other than `kill-daemon`.
- Break `previewsmcp serve` (stdio mode) — it's how Claude integrates.

## Success Criteria

Each is testable and directly observable.

1. **Feature parity:** every MCP tool has a CLI equivalent. For each tool, an integration test drives the CLI command and asserts the same observable behavior as the MCP tool.
2. **Daemon auto-start:** `previewsmcp snapshot <file>` works with no prior daemon. Liveness check → auto-start → RPC → result. End-to-end < 5s on local dev.
3. **Session reuse:** with `previewsmcp run fileA.swift` active, `previewsmcp snapshot fileA.swift` captures the live window (verified by trait state) rather than creating a fresh session.
4. **Magical ephemeral fallback:** with no session active, `previewsmcp snapshot fileA.swift` creates an ephemeral session, captures, tears down — behavior equivalent to today's one-shot.
5. **Multi-session:** two concurrent `run` invocations on different files coexist. `snapshot --file X` and `snapshot --file Y` each route correctly.
6. **Sole-session default:** with exactly one session, `previewsmcp snapshot` (no flag) targets it. With zero or multiple, errors clearly.
7. **Docker-style lifecycle:** Ctrl+C on attached `run` stops the session; `run --detach` leaves it alive; `stop` cleans up detached sessions.
8. **Liveness resilience:** kill the daemon manually (`kill -9`); next CLI command auto-starts a fresh daemon. Stale `serve.sock` is cleaned automatically.
9. **No regressions:** `previewsmcp serve` (stdio mode) still passes all existing `MCPIntegrationTests`. CLI tests that don't exercise daemon-specific paths stay green.
10. **CI velocity:** `build-and-test` runtime stays within 2× today's baseline. Daemon startup doesn't multiply subprocess overhead.

## Implementation Plan (Stacked PRs)

Each PR merges to main independently, validated before starting the next.

1. **Daemon foundation**
   `ServeCommand --daemon` flag, Unix socket transport, PID file, `status`, `kill-daemon`, `DaemonClient` with auto-start. `MCPServer.swift` refactor to share `Compiler`. Session RPCs (`session/list`, `session/findByFile`, `session/latest`). No new user-facing CLI commands yet — only the daemon itself and lifecycle.

2. **`run` migration**
   `run` becomes a `DaemonClient` wrapper: starts session in the daemon, streams progress/logs, blocks on Ctrl+C. Add `--detach`. Preserve existing behavior otherwise.

3. **`snapshot` migration**
   Magical reuse-or-ephemeral via daemon. Replace today's direct session creation with `DaemonClient` calls. `SessionResolver` introduced here.

4. **`configure`** — new command; trait changes on a live session.

5. **`switch`** — new command; active preview index change.

6. **`elements`** — new command; accessibility tree (iOS).

7. **`touch`** — new command; tap/swipe injection (iOS).

8. **`simulators`** — static list. Parallel with any other task; small, isolated.

9. **`stop`** — new command; session teardown. Could land with PR 1 or later; low dependency.

10. **`variants` migration** — move to daemon. Cleanup pass after parity is achieved.

Tasks within each PR follow `incremental-implementation`: build → test → commit.

## Open Questions

None blocking. Items to decide during implementation:

- Does `NWEndpoint.unix(path:)` + `NetworkTransport` work out of the box, or do we need a bespoke Unix socket transport? Check during PR 1.
- Version mismatch handling: if daemon was started by an old binary and CLI is newer, auto-restart or error? Defer until someone hits it.
- `status` output format: text, or JSON for scripting? Start with text; add `--json` if needed.
- Should `run --detach` print the session UUID to stdout (scriptable) and a human line to stderr? Likely yes; confirm during PR 2.

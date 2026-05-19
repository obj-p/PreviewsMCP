# Path resolution

Paths supplied to the CLI are inconsistently normalized — most file arguments collapse `.`/`..` but no
argument expands `~`, only one path in the codebase resolves symlinks, and at least one declared option
(`RunCommand.config`) is never read. This document specifies a single canonicalization rule and a
helper applied at argv parse time across every CLI subcommand and at the daemon boundary.

## Current state (audit)

`URL(fileURLWithPath:)` on macOS:
- Resolves relative paths against the process's current working directory.
- Treats `~` as a literal character — **no tilde expansion**.
- Does not resolve symlinks.

`.standardizedFileURL`:
- Collapses `.` / `..` segments and removes redundant separators.
- **Does not** resolve symlinks (that's `.resolvingSymlinksInPath()`).

What each command does today:

| Argument | Command(s) | Current handling | Tilde? | Symlink? | Existence checked? |
|---|---|---|---|---|---|
| `file` (Swift source) | run, list, snapshot, variants, session-targeting | `URL(fileURLWithPath:).standardizedFileURL` | ❌ | ❌ | ✅ (run/snapshot/variants) |
| `--project` | run, snapshot, variants | raw string, no normalization | ❌ | ❌ | ❌ |
| `--config` | snapshot, variants | raw string, passed through; `loadProjectConfig` uses it as-is | ❌ | ❌ | ❌ |
| `--config` | run | **declared but never used** (vestigial) | n/a | n/a | n/a |
| `--output` | snapshot | `URL(fileURLWithPath: output)` only | ❌ | ❌ | n/a |
| `--output-dir` | variants | `URL(fileURLWithPath: outputDir)` only | ❌ | ❌ | n/a |
| Self-binary path (for daemon respawn) | `SelfPath.swift:30` | `URL(fileURLWithPath: raw).resolvingSymlinksInPath().path` | ❌ | ✅ | n/a |
| `PREVIEWSMCP_DIR` override | `DaemonPaths.swift:18` | `URL(fileURLWithPath: override, isDirectory: true)` | ❌ | ❌ | n/a |

Citations: `RunCommand.swift:82`, `ListCommand.swift:21`, `SnapshotCommand.swift:122, 192, 333`,
`VariantsCommand.swift:127, 151, 199`, `SessionResolver.swift:47`, `SelfPath.swift:30`,
`DaemonPaths.swift:18`.

## Problems

1. **`~/foo.swift` fails.** A user typing `previewsmcp run ~/Projects/foo/View.swift` from a
   non-tilde-expanding context (e.g., `Process` spawning without a shell, an MCP client argv) gets
   `File not found: ~/Projects/foo/View.swift`. Same for `--project`, `--config`, `--output`,
   `--output-dir`.
2. **Symlinks resolve inconsistently.** Self-binary path uses `resolvingSymlinksInPath`; every user-
   provided path does not. A user-symlinked source file confuses the file watcher (watcher watches
   the symlink; editor save targets the real file). The pending FSEvents work (`filewatcher.md`) plans
   to `realpath()` watch paths at the watcher boundary, but the path travels through several layers
   before getting there.
3. **`--project` is fully un-normalized.** `previewsmcp run foo.swift --project ./MyProj` sends
   `"./MyProj"` to the daemon verbatim. Auto-discovery still works (the daemon has its own logic), but
   if the user explicitly passes a path expecting it to be honored, surprise.
4. **`RunCommand.config` is dead code.** Declared at `RunCommand.swift:67`, never referenced in
   `run()`. Either wire it through to `preview_start` (matching `SnapshotCommand`/`VariantsCommand`) or
   delete the option.

## Proposed canonicalization rule

One helper in `PreviewsCore`, called at every parsing site:

```swift
extension Path {
    /// Canonicalize a user-supplied path:
    /// 1. Expand leading `~` and `~user` against the user's home directory.
    /// 2. Resolve relative paths against the current working directory.
    /// 3. Collapse `.`/`..` segments.
    /// 4. Resolve symlinks once.
    ///
    /// Returns an absolute, symlink-free, lexically normalized path string.
    /// Does not check existence — callers decide whether non-existent paths
    /// are valid for their use case (output paths often are; input paths are
    /// not).
    static func normalize(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let url = URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        return url.path
    }
}
```

`expandingTildeInPath` handles `~` and `~user` (via `getpwnam`) per `NSString` docs. `URL(fileURLWithPath:)`
on the result resolves relatives against pwd. `.standardizedFileURL` collapses segments.
`.resolvingSymlinksInPath()` follows every link.

### Where the helper lives

`PreviewsCore` — alongside `FileWatcher` and other path-adjacent infrastructure. After the
`PreviewsBuild` extraction (see `modularization.md`), it stays in `PreviewsCore` since both CLI and
build-system modules need it.

### Why resolve symlinks at the CLI boundary (not just the watcher)

Several daemon-side comparisons key off the file path: `SessionResolver.swift:47` matches sessions by
their starting file path, the cross-process `SessionRegistry` persists paths, and
`preview_configure`/`preview_switch` look up sessions by `--file <path>`. If the CLI normalizes early
and consistently, two invocations referencing the same file via different paths (`./View.swift`,
`/abs/View.swift`, a symlink, `~/proj/View.swift`) resolve to one canonical key everywhere. Doing it
only at the watcher misses the session-lookup paths.

### When NOT to resolve

- **Output paths that don't exist yet** (`SnapshotCommand.output`, `VariantsCommand.outputDir`).
  `.resolvingSymlinksInPath()` is a no-op for non-existent paths (returns the input lexically
  standardized), so calling `normalize` on them is safe and gives consistent absolutization. No
  existence check.
- **Hardcoded internal paths** (`/usr/bin/tail`, daemon-managed paths under `~/.previewsmcp`).
  Internal; not user-supplied; skip.

## Where the normalization happens

**One boundary: the daemon.** All MCP tool handlers normalize path-shaped arguments on receipt
(`filePath`, `projectPath`, `config`, output paths). This covers every entry point — CLI commands
going through `DaemonClient`, direct MCP clients (Claude Code, Cursor) bypassing the CLI, and the
stdio `serve` mode used by IDE integrations. CLI-side normalization is redundant and would split the
canonicalization rule across two call sites.

The exceptions are CLI-side validations that need a usable path *before* the daemon round-trip:

- `RunCommand.swift:82-84` / `SnapshotCommand.swift:122-124` / `VariantsCommand.swift:127-129` —
  existence check. These need to print a fast local error for `~/missing.swift` rather than
  round-tripping a not-found to the daemon. So CLI normalizes `file` for the existence check, then
  passes the user's original string to the daemon (which renormalizes on receipt).
- `ListCommand.swift:21-22` — runs entirely client-side (`PreviewParser.parse(fileAt:)`), no daemon
  involved. Normalizes locally.
- `SessionResolver.swift:47` — `--file` lookup is performed daemon-side already; the lookup key just
  needs to match the daemon's canonical form, which the daemon produces from its own normalization.

| Site | Change |
|---|---|
| Daemon-side `preview_start`, `preview_snapshot`, `preview_variants`, `preview_configure`, `preview_switch`, `preview_buildinfo` handlers | Normalize every path-shaped field (`filePath`, `projectPath`, `config`, `outputPath`) on receipt via `Path.normalize`. |
| Daemon-side `SessionResolver` (when looking up by file) | Normalize incoming `file` argument before the lookup; sessions are keyed on the normalized path so this just makes the key consistent. |
| `RunCommand.swift:82` / `SnapshotCommand.swift:122, 192` / `VariantsCommand.swift:127, 199` | Normalize `file` for the local existence check only. Continue passing the user's original string to the daemon. |
| `ListCommand.swift:21` | Normalize `file` — runs client-side. |
| `RunCommand.swift:67` | **Decide:** wire `--config` through to `preview_start` like snapshot/variants, or delete the option. |
| `DaemonPaths.swift:18` | Normalize the `PREVIEWSMCP_DIR` env override (server-side configuration, daemon-internal). |

## Tests

`PreviewsCoreTests/PathTests.swift` (new):

- `~/foo` → `/Users/<me>/foo`.
- `~root/foo` → `/var/root/foo` (or whatever `getpwnam("root")` returns).
- `./a/../b` → `<cwd>/b`.
- A symlink `link -> /tmp/target` → `/tmp/target`.
- Non-existent path `~/nope` → `/Users/<me>/nope` (no error, lexical).
- A literal `~` (a file actually named `~`) — should the helper preserve it? `expandingTildeInPath`
  expands; users who genuinely have a file named `~` are vanishingly rare and can use `./~`. Document
  and accept.
- `""` → `""` (or document the edge — `expandingTildeInPath` returns `""`, `URL(fileURLWithPath: "")`
  produces a URL with `.path == "/"` on macOS, which is wrong). Add an `assert` or early-return guard.

Integration tests: pass `~/proj/View.swift` to `run`, `snapshot`, `variants` via a non-shell-expanding
spawn (`Process` with `arguments: ["~/..."]` directly) and assert the file is found.

## Out of scope (for this doc)

- Watching directory trees for source-tree-wide changes (covered in `filewatcher.md`).
- Project auto-discovery rules (the daemon's existing logic for finding `Package.swift` /
  `.xcodeproj` upward from the source file). Normalization happens at the boundary; auto-discovery
  consumes the normalized path.
- Windows-style path handling. PreviewsMCP is macOS-only.

# Modularization

The purpose of this document is to rework the module layout of PreviewsMCP.

## Proposed module layout

```
Sources/
├── previewsmcp/            CLI executable: argparser + all subcommands (including `serve`)
├── PreviewsMCPServer/      MCP server library: handler registry, schemas, stdio + UDS hosting
├── PreviewsMCPClient/      MCP-over-UDS client: auto-spawn, version-mismatch restart
├── PreviewsMCPProtocol/    Wire-contract DTOs shared by server (encode) and client (decode)
├── PreviewsSession/        Session layer: SessionRegistry, SessionRouter,
│                           IOSSessionManager, platform handle adapters
├── PreviewsBuild/          Build subsystem: build-system source enumerators (SPM/Xcode/Bazel),
│                           Compiler, StableModuleCompiler, ThunkCompiler, RuntimeDylibBuilder
├── PreviewsCore/           Platform-agnostic: parser, traits, body kind, literal differ,
│                           file watcher, source templates (DesignTimeStore, PreviewBridge),
│                           DylibLoader
├── PreviewsIOS/            iOS host app + iOS session implementation
├── PreviewsMacOS/          macOS host app + macOS session implementation
├── PreviewsSetupKit/       Public library — `PreviewSetup` protocol for user apps
└── SimulatorBridge/        Obj-C interface to CoreSimulator.framework
```

**Single binary.** `previewsmcp` links both `PreviewsMCPClient` and `PreviewsMCPServer` — ADB-style. CLI
subcommands (`run`, `list`, `snapshot`, …) use the client; `previewsmcp serve` hosts the server (stdio or
`--daemon` UDS). The MCP protocol is the only IPC; the CLI's "daemon client" is an MCP client speaking to
the server over UDS.

### Dependency direction

```
previewsmcp ──▶ PreviewsMCPClient ──▶ PreviewsMCPProtocol
            └─▶ PreviewsMCPServer ──▶ PreviewsSession ──▶ PreviewsBuild ──▶ PreviewsCore
                                                       └▶ PreviewsIOS    ──▶ SimulatorBridge
                                                       └▶ PreviewsMacOS
                                  └─▶ PreviewsMCPProtocol

PreviewsSetupKit   (standalone library product — no internal deps)
```

### What moves where

Today's `Sources/PreviewsCLI/` (~30 files) splits into four targets:

**→ `PreviewsMCPServer/`** (the server library)
- `MCPServer.swift`, `MCPServerSupport.swift`, `MCPContentHelpers.swift`, `MCPParamExtraction.swift`
- `Handlers/*` (12 tool handlers + `HandlerContext`, `ToolHandler`, `ToolName`, `TraitPropertySchema`)
- `DaemonListener.swift` → `UDSListener.swift`
- `DaemonPaths.swift` → `ServerPaths.swift`
- `StallTimer.swift`
- Public entry points like `PreviewsMCPServer.runStdio(host:)` / `PreviewsMCPServer.runUDS(host:)`
  called from `previewsmcp/ServeCommand.swift`.

**→ `PreviewsMCPClient/`** (the client library)
- `DaemonClient.swift` → `MCPServerClient.swift`
- `DaemonClientChannel.swift`, `DaemonProbe.swift`, `DaemonLifecycle.swift`, `DaemonRestart.swift`
- `DaemonToolError.swift`
- `SelfPath.swift`

**→ `PreviewsMCPProtocol/`** (shared wire types)
- `DaemonProtocol.swift` → `MCPToolDTOs.swift`. No internal dependencies — pure Codable DTOs so
  both server and client can depend on it without depending on each other.

**→ `previewsmcp/`** (CLI executable)
- `PreviewsMCPApp.swift`, all `*Command.swift` files (including `ServeCommand.swift`)
- `SessionResolver.swift`, `SessionTargetingOptions.swift`
- `ServeCommand` calls into `PreviewsMCPServer.run*` entry points — keeps `ArgumentParser` out of
  the server library.

### `PreviewsEngine` → `PreviewsSession` (rename + relocate misfits)

`PreviewsEngine` is renamed to `PreviewsSession` — singular, matching the Apple-style convention used by
`PreviewsCore`, `PreviewsIOS`, `PreviewsMacOS`, `PreviewsSetupKit`. "Engine" was a vague placeholder;
"Session" precisely names what the module owns. Four files currently in the module are not session-related
and move elsewhere:

| File | New home | Why |
|---|---|---|
| `BuildHelpers.StderrProgressReporter` | `previewsmcp/` | CLI-side stderr output |
| `BuildHelpers.loadProjectConfig` | `PreviewsCore` | Project-config loading is core, not session |
| `TraitHelpers` | `PreviewsMCPServer` | Produces user-facing strings shown in MCP tool results |
| `ConfigCache` | `PreviewsMCPServer` | Instantiated once at server startup, shared across handlers |
| `TempDirCleanup` | `PreviewsMCPServer` | Called at server startup |

After the moves, `PreviewsSession` contains exactly five files: `SessionRegistry`, `SessionRouter`,
`IOSSessionManager`, `IOSPreviewHandle`, `MacOSPreviewHandle`.

### Extract `PreviewsBuild` from `PreviewsCore`

The build pipeline (per-build-system source enumeration + compile orchestration) is large enough and
conceptually distinct enough to warrant its own module. Moves out of `PreviewsCore`:

- `BuildSystem`, `BuildSystemSupport`, `BuildContext`, `Toolchain`
- `SPMBuildSystem`, `XcodeBuildSystem`, `BazelBuildSystem`, `SPMBuildRecovery`
- `Compiler`, `AsyncProcess`
- New compilers introduced by [`thunk-architecture.md`](thunk-architecture.md):
  `RuntimeDylibBuilder`, `StableModuleCompiler`, `ThunkCompiler`

`PreviewsCore` retains: parser, traits, body kind, literal differ/region/info, file watcher,
`DesignTimeStore` and `PreviewBridge` source templates, `DylibLoader`,
`ProjectConfig`, `ProgressReporter`, `SetupBuilder`, `SetupCache`.

`PreviewSession*` moves out of `PreviewsCore` — see the next subsection.

See [`thunk-architecture.md`](thunk-architecture.md) for the new compilers' responsibilities and the
three-dylib hot-reload model that drives this split.

### Targets vs sessions

Today's `PreviewSession` (`Sources/PreviewsCore/PreviewSession.swift`) conflates two distinct concerns:

- **Target-level state.** Build context, source-file list, swiftc invocation, compiled dylib path,
  project config. Shared across every preview against the same SPM/Xcode/Bazel target.
- **Session-level state.** Active `#Preview` index, applied traits, live host handle (NSWindow on
  macOS / simulator device on iOS), preview-file watcher.

The thunk-architecture work in [`thunk-architecture.md`](thunk-architecture.md) exposes this conflation
as friction. Two `previewsmcp run` invocations against different files in the same target should share
one `libUserModule.dylib`; with target state buried inside `PreviewSession`, sharing requires either
duplication or external bookkeeping. It also creates a circular dependency: if `Compiler` moves to
`PreviewsBuild` while `PreviewSession` stays in `PreviewsCore`, `PreviewsCore` ends up depending on
`PreviewsBuild`.

Resolve by splitting the type:

- **`BuildTarget`** *(new, in `PreviewsBuild`)*. Keyed on `(projectPath, targetName, swiftcFlagsHash)`.
  Owns the stable module dylib lifecycle, the module watcher (non-preview file edits), the
  `BuildSystem` instance, and project config. Refcounts attached sessions. Daemon-scoped — one instance
  per distinct target across the daemon's lifetime.
- **`PreviewSession`** *(moves to `PreviewsSession`)*. Keyed on session UUID. References its
  `BuildTarget` by ID. Owns the thunk dylib, the preview-file watcher, the host (simulator device or
  NSWindow), and the applied traits.
- **`PreviewSessionHandle`** (protocol) stays in `PreviewsCore` so the platform handle adapters in
  `PreviewsIOS` / `PreviewsMacOS` don't need to import `PreviewsSession`.

Dependency direction (final):

```
previewsmcp ──▶ PreviewsMCPClient ──▶ PreviewsMCPProtocol
            └─▶ PreviewsMCPServer ──▶ PreviewsSession ──▶ PreviewsBuild ──▶ PreviewsCore
                                                       └▶ PreviewsIOS    ──▶ SimulatorBridge
                                                       └▶ PreviewsMacOS
                                  └─▶ PreviewsMCPProtocol
```

No circular dependency. `PreviewSession` no longer directly invokes `Compiler` — it asks its
`BuildTarget` for build artifacts, and the target hides whether they're cached or freshly produced.

**Lifecycle.**

| Event | Where it happens |
|---|---|
| `preview_start` arrives | Daemon resolves `(project, target)` from the request, looks up or creates a `BuildTarget` |
| Stable module compile | `BuildTarget.ensureStableModule()` — idempotent; first session pays, subsequent attach gets it cached |
| Thunk compile | `BuildTarget.compileThunk(for: previewFile)` |
| Non-preview file edit | `BuildTarget.rebuildStableModule()` invalidates and rebuilds every attached session's thunk |
| `preview_switch` | Session-scoped: `dlsym` on the already-loaded thunk |
| Preview-file edit | Session-scoped: thunk-only rebuild via `BuildTarget.compileThunk` |
| `preview_stop` | `BuildTarget.detach(sessionID)` — refcount-- |
| Refcount → 0 | Target stays warm briefly (TBD: cache-and-evict policy), then `dlclose` stable dylib |

This split is worth doing independently of the thunk architecture — `BuildTarget` is the right
abstraction for "the thing being previewed," and decoupling it from session lifecycle improves the
multi-session tests we already have.

After the moves, file inventory:

- **`PreviewsBuild`**: `BuildSystem`, `BuildSystemSupport`, `BuildContext`, `Toolchain`,
  `SPMBuildSystem`, `XcodeBuildSystem`, `BazelBuildSystem`, `SPMBuildRecovery`, `Compiler`,
  `AsyncProcess`, `BuildTarget` *(new)*, `RuntimeDylibBuilder` *(new)*, `StableModuleCompiler`
  *(new)*, `ThunkCompiler` *(new)*.
- **`PreviewsSession`**: `SessionRegistry`, `SessionRouter`, `IOSSessionManager`, `IOSPreviewHandle`,
  `MacOSPreviewHandle`, `PreviewSession` *(moved from Core)*.
- **`PreviewsCore`**: `PreviewSessionHandle` *(protocol stays)*, plus parser/traits/body-kind/literal/
  watcher/templates/loader as before.

### What does NOT change

- `PreviewsCore`, `PreviewsIOS`, `PreviewsMacOS`, `PreviewsSetupKit`, `SimulatorBridge` keep their current
  responsibilities and dependencies.
- The wire protocol stays MCP. There is no second protocol invented for CLI ↔ server.
- Stdio mode and `--daemon` UDS mode remain the two server transports.

### Host-app source

iOS preview rendering requires a separate signed app running in the simulator — different from macOS,
where the daemon process IS the app. The iOS host-app source (`HostApp.swift`, `Info.plist`, `AppIcon.png`)
is consumed only by the `EmbedHostAppSource` build plugin, which base64-encodes the bytes into a generated
Swift constant that `PreviewsIOS` materializes into a `.app` on disk at session start.

Today these files live at the repo root under `HostAppSource/` — physically separated from the iOS target
that owns them — because SwiftPM would otherwise try to compile the iOS-only `@main UIApplicationDelegate`
as part of the macOS build. The orphaned location is a workaround for SPM's source-discovery rules.

**Move into the target tree with an explicit exclude:**

```
Sources/PreviewsIOS/HostApp/      ← excluded from compilation; read by the build plugin
    HostApp.swift
    Info.plist
    AppIcon.png
```

`Package.swift` change:

```swift
.target(
    name: "PreviewsIOS",
    dependencies: ["PreviewsCore", "SimulatorBridge"],
    exclude: ["HostApp"],
    plugins: [.plugin(name: "EmbedHostAppSource")]
),
```

Plugin change (`Plugins/EmbedHostAppSource/EmbedHostAppSource.swift:28`):

```swift
let hostAppDir = context.package.directoryURL.appending(path: "Sources/PreviewsIOS/HostApp")
```

The plugin reads files via absolute URL and declares them as `inputFiles` so SPM continues to re-run the
build command on edits. Bazel doesn't reference `HostAppSource/` (`examples/bazel/BUILD.bazel` is a stub),
so this is an SPM-only change.

**Rename `Sources/PreviewsMacOS/HostApp.swift` → `PreviewHost.swift`.** It contains the public
`PreviewHost` class; the current filename collides in name with the iOS host source and conveys nothing
about what's inside. One-line `git mv`.

**Stale references to clean up** (independent of the move — commit `d3e0e77` promoted iOS host source out
of a single `IOSHostAppSource.swift` blob, but these spots still mention it):

- `.swiftlint.yml:8` excludes a file that no longer exists.
- `docs/architecture.md:35`, `docs/preview-fidelity.md:510-614`.
- `Sources/PreviewsCore/BodyKind.swift:14`, `Tests/PreviewsCoreTests/BodyKindCodeContractTests.swift:11`.
- `AGENTS.md:60, 132` need the new path post-move.

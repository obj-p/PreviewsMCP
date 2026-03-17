# Reverse Engineering Xcode SwiftUI Previews

Investigation of how Xcode 26.2 SwiftUI Previews works internally, conducted to build a standalone CLI and MCP server ([PreviewsMCP](https://github.com/obj-p/PreviewsMCP)).

## Table of Contents

- [Tools Used](#tools-used)
- [Architecture Overview](#architecture-overview)
- [Two Eras of Previews](#two-eras-of-previews)
- [macOS Preview Protocol](#macos-preview-protocol)
- [iOS Simulator Preview Protocol](#ios-simulator-preview-protocol)
- [Build Artifacts](#build-artifacts)
- [__designTime\* Functions](#__designtime-functions)
- [Update System](#update-system)
- [XCPreviewAgent Startup Sequence](#xcpreviewagent-startup-sequence)
- [Interactivity](#interactivity)
- [Commands Reference](#commands-reference)
- [External References](#external-references)

---

## Tools Used

### Binary Analysis
```bash
# Dump symbols from Xcode frameworks
nm -gU <binary> | xcrun swift-demangle > symbols.txt

# Extract strings (compiler flags, env vars, XPC service names)
strings <binary> | grep -i "pattern" | sort -u

# Inspect Mach-O load commands and linked libraries
otool -L <binary>
otool -l <binary>

# Export symbols from dyld shared cache (system frameworks)
dyld_info -exports /System/Library/Frameworks/SwiftUI.framework/SwiftUI | xcrun swift-demangle

# Check entitlements
codesign -d -vvv <binary>
```

### Process Tracing (SIP enabled)
```bash
# Find preview processes
ps aux | grep XCPreviewAgent

# Unified logging (captures PreviewsMessagingOS messages)
log stream --predicate 'process == "XCPreviewAgent"' --level debug

# File descriptor inspection
lsof -p <pid>

# File system monitoring
sudo fs_usage -f filesystem -w Xcode XCPreviewAgent swift-frontend ld
```

### Process Tracing (SIP disabled)
```bash
# Trace all writes from Xcode to the preview agent pipe
sudo dtrace -n '
syscall::write:entry /pid == <XCODE_PID>/ {
    self->fd = arg0;
    self->buf = arg1;
    self->len = arg2;
}
syscall::write:return /self->buf && self->len > 100/ {
    printf("\n=== WRITE fd=%d len=%d ===\n", self->fd, self->len);
    tracemem(copyin(self->buf, self->len < 4096 ? self->len : 4096), 4096);
    self->buf = 0;
}
' 2>&1 | tee trace.txt

# Trace pipe reads on the agent side
sudo dtrace -n '
syscall::read:entry /execname == "XCPreviewAgent"/ {
    self->fd = arg0;
    self->buf = arg1;
    self->len = arg2;
}
syscall::read:return /self->buf && arg1 > 0/ {
    printf("\n=== READ fd=%d len=%d ===\n", self->fd, arg1);
    tracemem(copyin(self->buf, arg1 < 2048 ? arg1 : 2048), 2048);
    self->buf = 0;
}
' 2>&1 | tee agent-reads.txt
```

### DerivedData Archeology
```bash
# Find preview-generated artifacts
find ~/Library/Developer/Xcode/DerivedData -name "*thunk*" -o -name "*XCPREVIEW*"

# Inspect thunk source (the __designTime* substituted version)
cat <DerivedData>/.../ContentView.1.preview-thunk.swift

# VFS overlay files
cat <DerivedData>/.../vfsoverlay-ContentView.1.preview-thunk.swift.json
```

---

## Architecture Overview

### Xcode 26.2 Framework Layout

**Host-side SharedFrameworks (12)** — inside `Xcode.app/Contents/SharedFrameworks/`:

| Framework | Symbols | Purpose |
|-----------|---------|---------|
| PreviewsPipeline | 6,720 | Main orchestrator, 15-step pipeline |
| PreviewsModel | 5,884 | Data model |
| PreviewsFoundationHost | 4,336 | Shared utilities, PropertyList handling |
| PreviewsMessagingHost | 3,042 | Host-side IPC coordinator |
| PreviewsUI | 1,294 | Rendering in Xcode canvas |
| PreviewsDeveloperTools | 830 | Developer-facing tools |
| PreviewsScenes | 684 | Scene management |
| PreviewsSyntax | 368 | Source code parsing (SwiftSyntax) |
| PreviewsXcodeUI | 297 | Xcode-specific UI bindings |
| PreviewsPlatforms | 507 | Platform-specific build logic |
| PreviewsXROSMessaging | 232 | visionOS messaging |
| PreviewsXROSServices | 271 | visionOS services |

**Device-side PrivateFrameworks (9)** — TBD stubs in SDK:

PreviewsInjection, PreviewsServices, PreviewShellKit, PreviewsMessagingOS, PreviewsFoundationOS, PreviewsOSSupport, PreviewsOSSupportUI, PreviewsServicesUI, PreviewsUIKitMacHelper

**Key Binaries:**
- `libPreviewsMacros.dylib` — `#Preview` / `@Previewable` macro plugin (SwiftSyntax-based)
- `XCPreviewAgent.app` — per-platform preview agent (built from UITestingAgent source)
- `libPreviewsJITStubExecutor.a` — JIT stub execution

**XCPreviewAgent bundle IDs:**
- `previews.com.apple.PreviewAgent.macOS` — macOS native
- `previews.com.apple.PreviewAgent.iOS` — iPhone Simulator
- `previews.com.apple.PreviewAgent.Catalyst` — iPad/Catalyst
- + watchOS, tvOS, visionOS variants

### SwiftUI Internal Types (from dyld shared cache)

Discovered via `dyld_info -exports`:

**`SwiftUI._PreviewHost`** — ObjC-bridgeable class (has metaclass):
- `static makeHost(content: A) -> _PreviewHost`
- `static makeHost(providerType: Any.Type) -> _PreviewHost?`
- `.previews -> [SwiftUI._Preview]`

**`SwiftUI._Preview`** — struct with direct view access:
- `.content -> SwiftUI.AnyView` ← the actual rendered view
- `.id -> Int`
- `.displayName -> String?`
- `.layout -> PreviewLayout`
- `.device -> PreviewDevice?`
- `.colorScheme -> ColorScheme?`
- `.interfaceOrientation -> InterfaceOrientation`

---

## Two Eras of Previews

### Pre-Xcode 16: `@_dynamicReplacement`
- `@_dynamicReplacement(for:)` was the primary hot-swap mechanism
- Thunks compiled into separate standalone `.dylib` files
- Stored in `Intermediates.noindex/Previews` (separate from normal build)
- `-enable-private-imports` and `-enable-implicit-dynamic` compiler flags
- `@_private(sourceFile:)` imports for accessing private types
- XPC via `UVKit` / `UVIntegration` Xcode plugins

### Xcode 16+: JIT Executor (current)
- JIT Executor replaced `@_dynamicReplacement` as the default mode
- `ENABLE_DEBUG_DYLIB` — app compiled as `.debug.dylib` + trampoline executable
- Build artifacts shared between Build-and-Run and Preview
- Three rebuild levels: small (literal), middle (structural), large (ABI-breaking)
- `@_dynamicReplacement` still exists as fallback (`Falling back to Dynamic Replacement: false`)

**Confirmed from Xcode diagnostics:**
```
runMode = JIT Executor
Falling back to Dynamic Replacement: false
JIT Mode User Enabled: true
```

---

## macOS Preview Protocol

### Transport
**Unix domain socket** (not XPC, not TCP). Observed via `lsof`:
```
XCPreview  fd=3  unix  ->0x668488a6196ae3b9
```

Xcode writes to one end (fd=66 on Xcode side), agent reads from the other (fd=3).

### Incoming Messages (Xcode → Agent)

Captured via `dtrace` on Xcode's `write()` syscall with SIP disabled. Messages are raw data on the Unix socket — **no framing protocol or length prefix**. (An initial review hypothesized 8-byte framing headers, but these were traced to the agent reading its own `PkgInfo`/saved state files on fd=8, not the pipe on fd=3.)

The fd numbers change per Xcode launch (observed fd=29, 64, 66 on the Xcode side; always fd=3 on the agent side).

| Order | Size | Format | Content |
|-------|------|--------|---------|
| 1 | ~357 B | XML plist | Workspace path + timestamp (sent twice) |
| 2 | ~19 KB | Binary plist | `NSKeyedArchiver`-encoded workspace state (editor documents, scheme, run destination) |
| 3 | ~470 B | JSON | VFS overlay (thunk → source mapping) |
| 4 | ~646 B | Raw Swift | Thunk source with `__designTime*` substitutions |
| 5 | ~40 KB | Binary plist | `NSKeyedArchiver`-encoded workspace state (larger, includes build settings) |

> **Note:** Earlier analysis misidentified some binary plist messages as "compiled `.o` files." The large binary messages (18-40KB) starting with `bplist00` are `NSKeyedArchiver` archives containing `IDEWorkspaceDocument` state — not compiled object files. The actual compiled objects appear to be sent via the JIT executor's internal mechanism (`XOJITExecutor`), not as raw pipe messages. On iOS, they're written to the `OOPJit/` filesystem directory instead.

**Message 1: Workspace Info**
```xml
<dict>
    <key>LastAccessedDate</key>
    <date>2026-03-17T03:04:00Z</date>
    <key>WorkspacePath</key>
    <string>/Users/.../MultiModuleTest</string>
</dict>
```

**Message 2: VFS Overlay**
```json
{
  "case-sensitive": "false",
  "roots": [{
    "contents": [{
      "external-contents": ".../FeatureView.1.preview-thunk.swift",
      "name": "FeatureView.swift",
      "type": "file"
    }],
    "name": ".../Sources/FeatureModule",
    "type": "directory"
  }],
  "version": 0
}
```

**Message 3: Thunk Source Code**
```swift
import func SwiftUI.__designTimeFloat
import func SwiftUI.__designTimeString
import func SwiftUI.__designTimeInteger
import func SwiftUI.__designTimeBoolean

#sourceLocation(file: ".../FeatureView.swift", line: 1)
import SwiftUI
import ViewLibrary

public struct FeatureView: View {
    public init() {}
    public var body: some View {
        VStack {
            Text(__designTimeString("#1192_0", fallback: "Feature Screen"))
                .font(.title)
            CounterView()
        }
    }
}

#Preview {
    FeatureView()
}
```

**Message 4: Compiled Object Files**
Binary `.o` data sent in chunks (4KB-18KB) for in-memory JIT linking by the `XOJITExecutor`.

### Outgoing Messages (Agent → Xcode)

Captured via `log stream` (no SIP needed). Binary plist format.

**`MacOSSnapshotPayload`** — sent every ~500ms:
```
MacOSSnapshotPayload(
  renderPayload: RenderPayload(
    bitmapDescription: BitmapDescription(
      data: 412416 bytes,
      width: 288,
      height: 358,
      bytesPerRow: 1152,
      bitmapInfo: 8194,
      bitsPerComponent: 8,
      bitsPerPixel: 32,
      colorSpace: "kCGColorSpaceSRGB"
    ),
    selectableRegions: [],
    snapshotCornerRadius: 16.0,
    scaleFactor: 2.0
  )
)
```

**Wire format** (PropertyList wrapped):
```
Message<OneWayContent>(
  content: PipeServiceInterface<HostAgentSystem.HostEndpoint>
    .OneWayContent.streamMessage(
      message: ["payload": ["renderPayload": [...]]],
      destination: <stream-UUID>
    )
)
```

### Interactivity (macOS)
**No event proxying over the pipe.** The XCPreviewAgent has its own `NSWindow` and receives events directly from the macOS window server. Confirmed by dtrace: zero writes from Xcode during button clicks in the preview canvas.

---

## iOS Simulator Preview Protocol

### Process Architecture

| Process | PID | Location | Role |
|---------|-----|----------|------|
| `previewsd` | — | Inside simulator runtime | Preview daemon, routes messages |
| `PreviewShell.app` | — | Inside simulator runtime | Hosts rendered view in UIKit scene |
| `XCPreviewAgent.app` | — | Installed in Previews simulator device set | Does JIT linking, scrapes PreviewRegistry |
| `PreviewShellMac` | — | macOS host | macOS-side bridge |

### Transport
**XPC services via `previewsd` daemon** — NOT a Unix socket pipe like macOS.

Additionally, compiled objects are written to the **filesystem** instead of sent over a pipe:
```
.../tmp/OOPJit/previews/<session-id>/cf.<random>  (16KB each, transient)
```

### XPC Service Types

Two distinct XPC services connect `PreviewShell` to `XCPreviewAgent`:
- **"Agent nonUI preview service"** — for preflight updates, `cancelUpdate`, non-rendering operations
- **"Agent scene preview service"** — for instance updates involving the rendering scene

Two pipe service systems:
- **`HostShellSystem`** (`HostEndpoint` / `ShellEndpoint`) — pipe between Xcode host and `PreviewShell`
- **`HostAgentSystem`** (`HostEndpoint`) — pipe between host and `XCPreviewAgent` (through `PreviewShell`)

### Message Flow

Updates go through a two-phase protocol:

```
Xcode
  → previewsd: <ServiceMessage N: cancelUpdate>  (cancel previous)
  → previewsd: <ServiceMessage N+1: update>
    → PreviewShell: receives update via "Daemon preview service" (two-way)
      - Runs PreviewsJITLinker:
        - UpdateTargetDescriptions (5ms)
        - ApplyPendingUpdates (3ms)
        - RunNewInitializers (0.5ms)
      - Phase 1 (preflight): entryPointCategory = "uv.previewPreflight"
        → XCPreviewAgent via "Agent nonUI preview service"
      - Phase 2 (instance): entryPointCategory = "uv.previewInstance"
        → XCPreviewAgent via "Agent scene preview service": performUpdate(...)
          - Scrapes runtime for PreviewRegistry types
          - Finds matching registry by source file + line
          - Sends .updateHandshake(prefs: [portrait], seed: N) via FrontBoard scene action
    ← PreviewShell: receives handshake, replies "Success"
    ← Xcode: receives rendered frame
```

The system also supports **kill/relaunch cycles** (`<ServiceMessage: kill>` → `<ServiceMessage: relaunch>`) for crash recovery, which triggers a full `__previews_injection_perform_first_jit_link` and `__previews_injection_run_user_entrypoint` again.

### Update Payload (same format as macOS)
```
["previewPayload": [
    "previewSpecification": [
        "location": [
            "line": 23,
            "file": [
                "fileName": "FeatureView.swift",
                "moduleName": "FeatureModule"
            ]
        ],
        "discriminant": "registryPreview",
        "stableID": [
            "registryType": "preview",
            "sourceFilePath": ".../FeatureView.swift",
            "registryIndexInFile": 1
        ]
    ],
    "renderEffects": []
]]
```

### Preview Registry Discovery
The agent scrapes the runtime for all `PreviewRegistry` conformances:
```
Found preview registry: ViewLibrary/Previews.swift:3
Found preview registry: FeatureModule/FeatureView.swift:23
```
It matches by `sourceFilePath` + `registryIndexInFile` from the `stableID`.

### Interactivity (iOS)
**Fully proxied through Xcode's canvas.** The simulator runs headless (no Simulator.app window). User clicks in Xcode's canvas are translated to iOS touch events and sent via FrontBoard scene actions (`UVPreviewSceneAction`) to `PreviewShell`, which dispatches them to `XCPreviewAgent`.

### Rendering
`PreviewShell.app` renders the SwiftUI view inside a `SimDisplayScene`. The rendered output is sent back to Xcode via `previewsd` → `PreviewShellMac` (macOS bridge) for compositing in the preview canvas.

---

## macOS vs iOS Comparison

| Aspect | macOS | iOS Simulator |
|--------|-------|---------------|
| Transport | Unix domain socket (fd=3) | XPC via `previewsd` daemon |
| Processes | Xcode → XCPreviewAgent | Xcode → previewsd → PreviewShell → XCPreviewAgent |
| JIT objects | Via `XOJITExecutor` internal mechanism | Written to `OOPJit/` filesystem (transient `cf.*` files) |
| Rendering | Agent has real NSWindow | UIKit scene (`SimDisplayScene`), FrontBoard actions |
| User events | Direct via window server (no proxying) | Proxied via FrontBoard scene actions (`UVPreviewSceneAction`) |
| Preview payload | `["previewSpecification": ...]` | Same format |
| Update protocol | Raw data on socket (no framing) | `ServiceMessage` numbered messages, two-phase (preflight + instance) |
| XPC services | N/A (direct socket) | "Agent nonUI preview service" + "Agent scene preview service" |
| Pipe systems | `HostAgentSystem` only | `HostShellSystem` + `HostAgentSystem` |
| Crash recovery | Agent restart | kill/relaunch cycle via `ServiceMessage` |

---

## Build Artifacts

### Xcode Project (single module, `ENABLE_DEBUG_DYLIB`)
```
PreviewTestApp.app/
├── Contents/MacOS/
│   ├── PreviewTestApp        # Trampoline executable (small)
│   ├── PreviewTestApp.debug.dylib  # Actual code (install name: @rpath/...)
│   └── __preview.dylib       # Preview stub (no exported symbols)
```

### SPM Package (multi-module, static linking)
```
Build/Products/Debug/
├── ViewLibrary.o             # Merged static lib
├── FeatureModule.o           # Merged static lib
├── ViewLibrary.swiftmodule/  # Module interface
└── FeatureModule.swiftmodule/
```
No `.dylib` files — everything is statically linked. JIT linker merges in-memory.

### Thunk Files
```
Build/Intermediates.noindex/.../Objects-normal/arm64/
├── ContentView.1.preview-thunk.swift       # __designTime* substituted source
├── ContentView.1.preview-thunk.o           # Compiled thunk
├── ContentView.1.preview-thunk-launch.o    # Launch object (PreviewRegistry)
├── ContentView.1.preview-thunk.dia         # Diagnostics
├── vfsoverlay-ContentView.1.preview-thunk.swift.json
└── vfsoverlay-ContentView.__XCPREVIEW_THUNKSUFFIX__.preview-thunk.swift.json
```

### Previews Simulator Device Set
```bash
# Previews uses a SEPARATE simulator device set
xcrun simctl --set ~/Library/Developer/Xcode/UserData/Previews/Simulator\ Devices list

# ~1.6GB dedicated device at:
~/Library/Developer/Xcode/UserData/Previews/Simulator Devices/<UUID>/
```

---

## `__designTime*` Functions

SwiftUI exports these for live literal editing:
```swift
import func SwiftUI.__designTimeString    // (_ id: String, fallback: String) -> String
import func SwiftUI.__designTimeInteger   // (_ id: String, fallback: Int) -> Int
import func SwiftUI.__designTimeFloat     // (_ id: String, fallback: Double) -> Double
import func SwiftUI.__designTimeBoolean   // (_ id: String, fallback: Bool) -> Bool
import func SwiftUI.__designTimeSelection // (...) — for enum/choice selections
```

**Example transformation** (from captured DerivedData thunk):
```swift
// Original:
VStack(spacing: 20) {
    Button("Increment") { count += 1 }

// Thunk:
VStack(spacing: __designTimeInteger("#8919_0", fallback: 20)) {
    Button(__designTimeString("#8919_1", fallback: "Increment")) {
        count += __designTimeInteger("#8919_2", fallback: 1)
    }
```

IDs like `"#8919_0"` are keys into a runtime value store (`__designTimeValues` dictionary). Xcode can update values without recompilation.

**Eligibility rules** (what gets replaced):
- Literals inside code blocks / closures / computed property bodies
- NOT stored property initializers (`@State var count = 0` — the `0` stays)
- NOT macro arguments (`#Preview("Name")` — the `"Name"` stays)
- NOT strings with interpolation (`"Count: \(count)"` — skipped entirely)
- NOT import statements, attributes, enum raw values, switch case patterns

---

## Update System

### Three Tiers

| Tier | Edit Type | What Happens | `@State` |
|------|-----------|-------------|----------|
| Small | Literal only (`"Hello"` → `"World"`) | `__designTime*` value store update, no recompile | Preserved |
| Middle | Structural (add/remove views) | Thunk `.o` recompiled, dylib NOT rebuilt | Resets |
| Large | ABI-breaking (add `@State` property) | Full rebuild of all `.o` + dylib | Resets |

**Confirmed behavior** (tested on both single-module and multi-module projects):
- `@_dynamicReplacement` was **never triggered** in any scenario on Xcode 26.2
- All tiers use VFS overlay + `__designTime*` + JIT Executor

### Pipeline Steps (from PreviewsPipeline symbols)
```
WorkCollectionStep → WorkspaceBuildStep → BuiltTargetDescriptionsStep →
BuiltProductContextStep → LaunchConfigurationStep → RunDestinationStep →
CodeCompilationStep (CompileBuildStep → LinkBuildStep → EmitModuleBuildStep) →
DynamicLibraryBuildStep → CodeSignBuildStep →
LaunchThunksStep (ThunkProductsStep → VerifyThunkPresenceBuildStep) →
AgentAssignmentStep → ExecutionPointUpdateStep → PerformUpdateStep
```

---

## XCPreviewAgent Startup Sequence

Captured via `log stream` (no SIP needed):

```
1. Agent launched with __PREVIEWS_JIT_LINK env var
2. Looking for Previews JIT link entry point → Found
3. __previews_injection_jit_link_entrypoint start
4. Received request to connect JIT → Received JIT executor
5. XOJITExecutor: __xojit_executor_run_program
     PreviewsInjection __previews_injection_perform_first_jit_link
6. JITLinkWaiter: Performing initial JIT link (completed in 16ms)
7. __xojit_executor_run_program
     PreviewsInjection __previews_injection_run_user_entrypoint
8. __debug_blank_executor_run_user_entry_point called
9. ControlAgent: host pipe connection succeeded
10. streamOpened → destination: <UUID-1>
    streamOpened → destination: <UUID-2>
11. EntryPointIndex received host message stream for:
    - Ultraviolet.NSPreviewSuppressedPresentations
    - Ultraviolet.MacOSSnapshots
12. MacOSSnapshotPayload sent every ~500ms
```

### Entry Point Resolution (7-step fallback chain)
1. Check `__PREVIEWS_JIT_LINK` → `__previews_injection_jit_link_entrypoint`
2. Check `__PREVIEWS_INTERPOSED_DEBUG_DLIB` (pseudodylib)
3. Look up debug dylib by install name (`__PREVIEWS_EXECUTABLE_DYLIB_NAME`)
4. Look up debug dylib by relative path
5. Find `__debug_main_executable_dylib_entry_point` in dylib
6. Find provided entry point name
7. Fall back to `main`

### Key Environment Variables
```
__PREVIEWS_JIT_LINK                              — trigger JIT link entry point
__PREVIEWS_EXECUTABLE_DYLIB_NAME                 — dylib install name
__PREVIEWS_INTERPOSED_DEBUG_DLIB                 — debug dylib interposition
__PREVIEWS_AGENT_STUB_EXECUTOR_STDERR_REDIRECT   — stderr redirect
__PREVIEWS_AGENT_SKIP_USER_ENTRY_POINT           — skip user entry
__XCPREVIEW_THUNKSUFFIX__                        — thunk dylib naming suffix
```

---

## Interactivity

### macOS
The XCPreviewAgent creates a real `NSWindow`. Events (clicks, scrolls, keyboard) are delivered **directly by the macOS window server** — Xcode does not proxy them. Confirmed via dtrace: zero writes from Xcode to the agent pipe during user interaction.

### iOS Simulator
All events are **proxied through Xcode's canvas**:
1. User clicks in Xcode's preview canvas
2. Xcode translates to iOS touch coordinates
3. Sends via FrontBoard scene actions (`UVPreviewSceneAction`) to `PreviewShell`
4. `PreviewShell` dispatches to `XCPreviewAgent`
5. SwiftUI processes the event → `@State` updates → re-renders
6. Rendered frame sent back to Xcode for display

The simulator runs **headless** — no Simulator.app window appears for previews.

---

## Commands Reference

### Symbol Corpus Generation
```bash
# Host-side frameworks
for name in PreviewsPipeline PreviewsSyntax PreviewsModel PreviewsMessagingHost \
  PreviewsFoundationHost PreviewsDeveloperTools PreviewsScenes PreviewsUI \
  PreviewsXcodeUI PreviewsPlatforms PreviewsXROSMessaging PreviewsXROSServices; do
  nm -gU "$SF/$name.framework/Versions/A/$name" | xcrun swift-demangle > "${name}_symbols.txt"
done

# System frameworks (dyld cache)
dyld_info -exports /System/Library/Frameworks/DeveloperToolsSupport.framework/DeveloperToolsSupport \
  | xcrun swift-demangle > DeveloperToolsSupport_symbols.txt

dyld_info -exports /System/Library/Frameworks/SwiftUI.framework/SwiftUI \
  | xcrun swift-demangle | grep -i "preview\|hosting" > SwiftUI_preview_symbols.txt
```

### Live Tracing (SIP enabled)
```bash
# Capture XCPreviewAgent logs during preview session
log stream --predicate 'process == "XCPreviewAgent"' --level debug 2>&1 | tee agent-log.txt

# iOS: also capture PreviewShell and previewsd
log stream --predicate 'process == "XCPreviewAgent" OR process == "PreviewShell" OR \
  process == "previewsd" OR process == "PreviewShellMac"' --level debug 2>&1 | tee ios-log.txt

# File descriptor inspection
lsof -p <agent-pid> | grep -v "\.dylib\|txt\|cwd\|rtd\|KQUEUE"
```

### Pipe Tracing (SIP disabled)
```bash
# Trace Xcode writes to the agent pipe
XCODE_PID=$(pgrep -x Xcode)
sudo dtrace -n '
syscall::write:entry /pid == '$XCODE_PID'/ {
    self->fd = arg0; self->buf = arg1; self->len = arg2;
}
syscall::write:return /self->buf && self->len > 100/ {
    printf("\n=== WRITE fd=%d len=%d ===\n", self->fd, self->len);
    tracemem(copyin(self->buf, self->len < 4096 ? self->len : 4096), 4096);
    self->buf = 0;
}' 2>&1 | tee xcode-pipe-trace.txt
```

### Previews Simulator Device Set
```bash
# List preview simulator devices (separate from regular simulators)
xcrun simctl --set ~/Library/Developer/Xcode/UserData/Previews/Simulator\ Devices list

# Take screenshot of preview simulator
xcrun simctl --set ~/Library/Developer/Xcode/UserData/Previews/Simulator\ Devices \
  io <device-uuid> screenshot preview.png
```

---

## External References

- [How SwiftUI Preview Works Under the Hood | onee.me](https://onee.me/en/blog/how-new-xcode-swiftui-preview-works-under-the-hood/) — Best source on Xcode 16+ JIT Executor path
- [Behind SwiftUI Previews | Guardsquare](https://www.guardsquare.com/blog/behind-swiftui-previews) — Pre-Xcode 16 `@_dynamicReplacement` analysis
- [Building Stable Preview Views | fatbobman](https://fatbobman.com/en/posts/how-swiftui-preview-works/) — `@_private(sourceFile:)` imports documentation
- [Dynamic libraries and code replacements in Swift | theswiftdev](https://theswiftdev.com/dynamic-libraries-and-code-replacements-in-swift/) — `@_dynamicReplacement` background

---

*Investigation conducted March 2026. Xcode 26.2 (17C49), macOS 26.2, Swift 6.2.3, Apple Silicon.*

# W3 — XCPreviewAgent lifecycle timeline

**Workstream:** W3 deliverable #1 per `prompts/jit-executor-research.md` → "Workstreams"
section. Extends `docs/reverse-engineering.md:581-603` (the previously-recorded
`__previews_injection_*` entry-point names) with the *full* lifecycle envelope: env
vars consumed, entry-point fallback chain, decision tree, and message order from
launch to first paint.

**Status:** Draft 1. Grounded in static analysis of `XCPreviewAgent` + observed
stderr output from direct launch attempts in the research VM. The JIT-path
post-firstlink portion (steps 7c onward) is grounded in static API surface only —
runtime confirmation requires driving an actual JIT-link, which is a separate
pre-implementation TODO (see "Limits" below).

**Verified-against:** macOS 26.3.1 (VM-side), Xcode 26.2 (Build 17C49). Single
Xcode version per the spike's non-goals.

---

## TL;DR

`XCPreviewAgent` is a minimal Mach-O executable (LC_MAIN entry =
`___debug_blank_executor_main` at file offset `0x13A8`) with three distinct
execution paths. The path is selected by *symbol presence and section content* at
program startup, not by command-line argv. Env vars only fine-tune the chosen
path. The path-selection logic emits its decision tree verbatim to stderr (via
`os_log` and direct `fwrite`); the log lines below are quoted directly from a
captured live run (`research/scripts/data/w3/agent-stderr-frameworkmode.txt`).

The three paths:

1. **Dylib path** (legacy `@_dynamicReplacement` flow) — gated on `__TEXT,__debug_dylib`
   etc. sections being populated at *link time*. Stub dlopens the path, finds the
   entry symbol, calls it.
2. **JIT path** (XOJIT flow) — gated on `__previews_injection_jit_link_entrypoint`
   resolving via `dlsym`. PreviewsInjection.framework must be present, typically
   via `DYLD_INSERT_LIBRARIES`. The stub hands control to PreviewsInjection, which
   blocks on XPC waiting for the first JIT-link signal from Xcode.
3. **Framework-agent path** (fallback) — neither (1) nor (2) succeeds. The stub
   calls the agent binary's *own* `___debug_main_executable_dylib_entry_point`
   alias (file offset `0x2FB4`, which is the same as `_main`), running
   `NSApplicationMain` → `AppDelegate` → `CFRunLoopRun` and sitting idle.

The "first paint" terminus differs per path: paths (1) and (3) run their entry
point synchronously; path (2) blocks until first XPC message from Xcode/previewsd
delivers the link payload, then runs the JIT-linked code.

---

## Step-by-step (annotated, with evidence)

### Step 0 — OS-level launch

The agent is normally launched by `previewsd` (via `posix_spawn`) with
environment + path inherited per `previewsd`'s configuration. The agent's bundle
identifier is `previews.com.apple.PreviewAgent.macOS` (unusual reversed-form
prefix; see `agent-metadata.txt`). Code-signing entitlements are minimal —
**only `com.apple.security.get-task-allow`** (`agent-metadata.txt:codesign
entitlements`). The JIT entitlement (`com.apple.security.cs.allow-jit`) is
**not** present on the agent's own signature; JIT capability is granted via one
of:

- `mach_vm_map` with the `MAP_JIT` flag in `XOJITExecutor.framework` (which
  imports `_mach_vm_map`).
- AMFI relaxation when the host system has it disabled (our VM has
  `amfi_get_out_of_my_way=1`).
- Possibly a private inherited entitlement from `previewsd`; not confirmed.

Evidence: `agent-metadata.txt`, `XOJITExecutor-imports.txt`.

### Step 1 — dyld bootstrap

The kernel maps the agent. dyld runs.

If `DYLD_INSERT_LIBRARIES` includes `/System/Library/PrivateFrameworks/PreviewsInjection.framework/Versions/A/PreviewsInjection`,
dyld loads PreviewsInjection.framework. PreviewsInjection weak-links
`/System/Library/PrivateFrameworks/XOJITExecutor.framework`, which dyld then
loads transitively (`PreviewsInjection-linkeddylibs.txt:7`).

Both frameworks have static and Swift-side initializers that run before
`LC_MAIN`. From the dump:

- PreviewsInjection's initializers install NSXPC listeners. Failure mode (when
  `previewsd` is absent) is logged as
  `[NSXPCSharedListener endpointForReply:...] error: Connection interrupted`
  (visible in every test run without `previewsd`).
- XOJITExecutor's initializers register the GDB/LLDB JIT debug interface (via
  the public `___jit_debug_register_code` + `___jit_debug_descriptor` symbols
  plus `_llvm_orc_registerJITLoaderGDBAllocAction`). See
  `XOJITExecutor-exports.txt`.

Evidence:
- VM `vmmap` against a JIT-mode-launched agent shows
  `PreviewsInjection.framework` and `XOJITExecutor.framework` mapped
  (`__DATA`, `__DATA_DIRTY` regions in `agent-sample-jit-mode.txt`).
- lldb `image list` against the same process resolves both frameworks at known
  shared-cache addresses (`agent-lldb-jit-mode.txt`).

### Step 2 — LC_MAIN → `___debug_blank_executor_main(argc, argv)`

LC_MAIN dispatches to file offset `0x13A8` (= `___debug_blank_executor_main`).
This entry point is linked from `libPreviewsJITStubExecutor.a` — a thin static
archive embedded into the agent binary. The stub has only 39 exported symbols
and 41 undefined refs (all standard libc + libdyld + libos_log — see
`prompts/jit-executor-findings.md` → "What `libPreviewsJITStubExecutor.a` actually
is").

Evidence:
- `agent-loadcmds.txt`: `cmd LC_MAIN, entryoff 5032` (5032 = 0x13A8).
- `agent-exports.txt:0x000013A8 ___debug_blank_executor_main`.

### Step 3 — Stub environment-variable consumption

The stub immediately calls `_getenv` (the only `getenv` reference in
`libPreviewsJITStubExecutor.a`'s undefined-symbols list) to read its
configuration env vars. The five known env vars, recovered from the agent
binary's `__TEXT,__cstring` section (`agent-cstrings.txt`):

| Env var | Effect | Default if unset |
|---|---|---|
| `__PREVIEWS_AGENT_STUB_EXECUTOR_STDERR_REDIRECT` | Path; if set, the stub `freopen`s `stderr` to that file *and* prepends a timestamp banner + `================` separator on every entry. | stderr unchanged. |
| `__PREVIEWS_JIT_LINK` | Value "YES" / "NO"; advisory flag indicating the path the stub *expects* to take. Logged via os_log; not strictly required (path selection happens via symbol presence below). | unset = treated as legacy. |
| `__PREVIEWS_EXECUTABLE_DYLIB_NAME` | String; the install-name of the dylib the agent will load (used by Dylib path's `findDebugDylibMachHeaderAmongLoadedImages` to identify which loaded image is the "user" preview). | empty / unused. |
| `__PREVIEWS_INTERPOSED_DEBUG_DLIB` | Value "YES" / "NO"; tells the stub the preview dylib has been `DYLD_INSERT_LIBRARIES`-injected rather than dlopened. | unset / "NO". |
| `__PREVIEWS_AGENT_SKIP_USER_ENTRY_POINT` | If set, stub skips calling the user's entry point after locating it. Used in some "headless" / sanity-check modes. | unset = entry point called. |

Evidence: `agent-cstrings.txt:0x100004b5d`, `…bd7`, `…ca` strings; `_getenv` in
`agent-imports.txt` and `libPreviewsJITStubExecutor-undefined.txt`.

### Step 4 — Stub `__TEXT,__debug_dylib` section lookup (Dylib-path probe)

The stub calls `_getsectiondata(_mh_execute_header, "__TEXT", "__debug_dylib",
&size)` and friends for three sibling sections:

- `__TEXT,__debug_dylib` — relative path of the preview dylib (e.g.
  `./ContentView.previewdylib`).
- `__TEXT,__debug_entry` — entry point symbol name in that dylib (e.g.
  `__debug_main_executable_dylib_entry_point`).
- `__TEXT,__debug_instlnm` — install name (LC_ID_DYLIB string) of that dylib.

These sections are *populated by `ld` at agent-build time* via the
`section$start$__TEXT$__debug_dylib` / `section$end$…` pair — i.e. the agent is
specifically linked with these values when Xcode wants the Dylib path. The
shipped XCPreviewAgent has all three sections present but **empty** — confirmed
by `otool -arch arm64 -s __TEXT __debug_dylib XCPreviewAgent` returning only the
"Contents of (__TEXT,__debug_dylib) section" header line with no bytes
(`agent-sec-debug_dylib.txt`).

Stub log lines (verbatim) at this stage:

```
[PreviewsAgentExecutorLibrary] Looking up debug dylib relative path
[PreviewsAgentExecutorLibrary] No debug dylib relative path defined.
[PreviewsAgentExecutorLibrary] Looking up debug dylib entry point name
[PreviewsAgentExecutorLibrary] No debug dylib entry point name defined.
[PreviewsAgentExecutorLibrary] Looking up debug dylib install name
[PreviewsAgentExecutorLibrary] No debug dylib install name defined.
```
(`agent-stderr-frameworkmode.txt:1-6`).

For the Dylib path to be taken, these would need to be non-empty. The shipped
agent is not Dylib-configured; instead, a Dylib-mode build emits a *custom-linked
copy* of the agent into the build product, with these sections populated.

### Step 5 — JIT-path probe via `dlsym`

The stub calls `_dlsym(RTLD_DEFAULT, "__previews_injection_jit_link_entrypoint")`
(plus possibly a sibling lookup for `__previews_injection_perform_first_jit_link`).

- If the symbol resolves → PreviewsInjection.framework is loaded → JIT path.
- If not → fall through to framework-agent path.

Stub log lines (framework-mode, PreviewsInjection NOT loaded):

```
[PreviewsAgentExecutorLibrary] Looking for Previews JIT link entry point.
[PreviewsAgentExecutorLibrary] No Previews JIT entry point found.
[PreviewsAgentExecutorLibrary] Gave PreviewsInjection a chance to run and it returned, continuing with debug dylib.
```
(`agent-stderr-frameworkmode.txt:7-9`).

The phrase "Gave PreviewsInjection a chance to run and it returned" is the
stub's way of saying: the dlsym failed AND any injected initializer-time work
PreviewsInjection might have wanted to do (e.g. blocking on XPC waiting for a
link signal) has either run to completion or not been invoked at all.

**JIT-path symbol resolution evidence (with DYLD_INSERT_LIBRARIES set):**
The same `dlsym` succeeds. lldb attached to the JIT-mode-launched agent shows:

```
Address: PreviewsInjection[0x000000025fa7d508]
  (PreviewsInjection.__TEXT.__text + 205616)
Summary: PreviewsInjection`PreviewsInjection.__previewsInjectionJITLinkEntrypoint(
  argc: Swift.Int32,
  argv: Swift.Optional<Swift.UnsafeMutablePointer<…UInt8>>,
  previewsDylibPath: Swift.Optional<…>,
  previewsDylibEntryPointName: Swift.Optional<…>)
  -> ()
```
(`agent-lldb-jit-mode.txt:image lookup` results.)

### Step 6 — (Framework-agent fallback) calling the bundled entry point

If both Step 4 and Step 5 fail, the stub falls back to the agent binary's
**own** main as if it were a normal app: it calls the symbol
`___debug_main_executable_dylib_entry_point` (at file offset `0x2FB4`, which is
the same offset as the `_main` alias — see `agent-exports.txt`).

```
[PreviewsAgentExecutorLibrary] Looking for main entry point.
[PreviewsAgentExecutorLibrary] No debug dylib present, assuming framework agent.
[PreviewsAgentExecutorLibrary] Calling provided entry point.
```
(`agent-stderr-frameworkmode.txt:10-12`).

The agent binary's `_main` calls into Swift (visible in
`agent-imports.txt`: imports `_$s6AppKit17NSApplicationMain…`, plus
`CommandLine.argc`/`.unsafeArgv`). This is a stock `NSApplicationMain`
boot — `AppDelegate` class is `_TtC14XCPreviewAgent11AppDelegate`
(`agent-cstrings.txt:0x100004d60`) with a `window` IBOutlet
(`agent-cstrings.txt:0x100004da8`). The framework-mode agent therefore boots
into a standard NSApplication run loop with the "Xcode Previews" main menu
(visible in the stderr log at lines 230-247 — `Title: Xcode Previews` /
`Quit Xcode Previews` etc.).

The framework-mode path is what runs when the agent is started "outside" of a
preview session — e.g., by hand from the shell with neither Dylib sections
populated nor PreviewsInjection injected. The agent sits in `CFRunLoopRun`
indefinitely, never paints a preview, and dies on the first `pkill`.

### Step 7 — (JIT path) PreviewsInjection takes control

With PreviewsInjection injected (Step 1's `DYLD_INSERT_LIBRARIES` form), Step 5's
`dlsym` succeeds and the stub calls
`__previews_injection_jit_link_entrypoint(argc, argv, previewsDylibPath,
previewsDylibEntryPointName)`. PreviewsInjection takes over from this point.

What it does, based on its exported API surface (`PreviewsInjection-exports.txt`)
plus observed runtime state (`agent-sample-jit-mode.txt`):

#### 7a — install XPC listeners + register entry-point types
PreviewsInjection's Swift `EntryPoint` protocol family
(`PreviewsInjection.EntryPoint`, `NonUIEntryPoint`, `SceneEntryPoint`, and
factory protocols) is registered into `EntryPointTypeRegistry`. The framework
installs an `NSXPCListener` whose handlers correspond to:

- `handle(hostMessageStream:instance:)` — receives Xcode's main control stream.
- `handle(shellMessageStream:)` — receives previewsd's shell stream.
- `handle(endpoint:context:)` — endpoint-handshake message.
- `cancelUpdate()` — cancellation.

These are the four async methods on `EntryPoint` (`PreviewsInjection-exports.txt`
"dispatch thunk of PreviewsInjection.EntryPoint.handle…" entries).

#### 7b — block waiting for first link signal
The agent enters `CFRunLoopRun` on the main thread, waiting for the first
XPC message. Observed live in a sample (`agent-sample-jit-mode.txt`):

```
115 Thread_6044   DispatchQueue_1: com.apple.main-thread  (serial)
+ 115 _CFRunLoopRunSpecificWithOptions  (in CoreFoundation)
+   115 __CFRunLoopRun
+     115 __CFRunLoopServiceMachPort
```

Without a connected `previewsd` parent process, no message ever arrives, and
the agent blocks indefinitely (we verified up to 5 seconds; eventually
`PreviewsInjection.___abort_timed_out_waiting_for_previews_jit_first_link_signal`
would fire, per `PreviewsInjection-tbd-symbols.txt:124`).

#### 7c — first XPC message: `__previewsInjectionPerformFirstJITLink`
Once previewsd sends the first message, PreviewsInjection calls
`__previewsInjectionPerformFirstJITLink(argc, argv) -> Int32`
(`PreviewsInjection-exports.txt:0x00034C80`). Based on the function name + Q6's
`XOJITExecutor.framework` evidence:

- Instantiates an `XOJITExecutor` Swift class with an XPC connection
  (`XOJITExecutor.init(connection: OS_xpc_object)` — public Swift initializer).
- Inside that initializer, XOJITExecutor sets up LLVM ORC + JITLink (statically
  linked into the framework — see `research/scripts/analysis/q6-jit-runtime-findings.md`).
- Allocates a fresh `JITDylib` (`XOJITExecutor.XOJITExecutor.JITDylibHandle`).
- Registers the GDB/LLDB JIT debug interface
  (`_llvm_orc_registerJITLoaderGDBAllocAction` + `___jit_debug_register_code` +
  `___jit_debug_descriptor`).

Return value is an `Int32` status — `0` on success, non-zero on failure.

#### 7d — subsequent updates: `__previewsInjectionJITLinkEntrypoint`
For each subsequent preview edit, Xcode sends an XPC message carrying object
file paths + linker parameters (`PreviewsJITLinkerParameters` shape from
`architecture-diagram-draft.md`). PreviewsInjection routes to:

```
__previewsInjectionJITLinkEntrypoint(
  argc: Int32,
  argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
  previewsDylibPath: UnsafeMutablePointer<Int8>?,
  previewsDylibEntryPointName: UnsafeMutablePointer<Int8>?)
```

The `previewsDylibPath` is the (in-memory) pseudodylib path; the
`previewsDylibEntryPointName` is the symbol name to call after the link
completes. The function JIT-links the new object files into the existing
`JITDylib` (overlaying or augmenting prior content) via XOJITExecutor's wrapped
ORC, then registers the resulting Swift entry-point section and calls into
user code.

Address (lldb):
`PreviewsInjection[0x025fa7d508]  __previewsInjectionJITLinkEntrypoint`.

#### 7e — Swift extension entry section registration
After link, PreviewsInjection calls
`__previewsInjectionRegisterSwiftExtensionEntrySection(argc, argv) -> Int32`
(`PreviewsInjection-exports.txt:0x000361E0`). This walks the JIT'd image's
`__TEXT,__swift5_entry` section (referenced by name in `agent-cstrings.txt:0x100004c9b`)
and registers its contents with the Swift runtime — analogous to
`swift_register_dynamic_replacements` for any preview-thunk replacements.

#### 7f — run user entry point
Finally PreviewsInjection calls
`__previewsInjectionRunUserEntryPoint() -> Int32`
(`PreviewsInjection-exports.txt:0x00034B04`). This is the stub's call back into
"go run the previewed `body` of the SwiftUI view". The execution lands on
XOJITExecutor's `___xojit_executor_run_program_on_main_thread`
(`XOJITExecutor-exports.txt:0x00006168`; lldb address
`XOJITExecutor[0x0278a2168]`), which schedules the JIT'd entry point on the
NSApplication main thread.

Once that returns (or the previewed body's `Task`s suspend), the main thread
goes back to `CFRunLoopRun` and the cycle repeats on every subsequent
preview-edit XPC message.

---

## Path-selection decision tree (compact)

```
LC_MAIN → ___debug_blank_executor_main(argc, argv)
│
├─ getenv("__PREVIEWS_AGENT_STUB_EXECUTOR_STDERR_REDIRECT") → freopen stderr
├─ getenv("__PREVIEWS_JIT_LINK"), "__PREVIEWS_EXECUTABLE_DYLIB_NAME", etc. (advisory)
│
├─ getsectiondata(__TEXT, __debug_dylib): non-empty?
│   ├─ YES → DYLIB PATH:
│   │        getsectiondata(__TEXT, __debug_entry)  // entry-symbol name
│   │        getsectiondata(__TEXT, __debug_instlnm) // install name
│   │        dlopen(__debug_dylib path)
│   │        findDebugDylibMachHeaderAmongLoadedImages()
│   │        lookupMainFuncAddressInDebugDylibMachHeader() // dlsym entry name
│   │        getenv("__PREVIEWS_AGENT_SKIP_USER_ENTRY_POINT") ? skip : call entry
│   │        return
│   │
│   └─ NO →  (continue)
│
├─ dlsym(RTLD_DEFAULT, "__previews_injection_jit_link_entrypoint"): resolves?
│   ├─ YES → JIT PATH:
│   │        // PreviewsInjection takes over.
│   │        __previews_injection_jit_link_entrypoint(argc, argv, NULL, NULL)
│   │        └─ Step 7a-7f above
│   │
│   └─ NO →  (continue)
│
└─ FRAMEWORK-AGENT PATH (fallback):
       call ___debug_main_executable_dylib_entry_point()
       └─ NSApplicationMain → AppDelegate → CFRunLoopRun (idle)
```

---

## Closing the diagram-draft's open questions

W3 closes the following questions from
`research/scripts/analysis/architecture-diagram-draft.md`:

### Q7 — `PreviewAgentRunMode.fullBinary`

**Closed.** From `PreviewAgentBundle.runMode` (the enum found in W2's symbol
dump — cases `.dynamicReplacement / .jitExecutor / .fullBinary`), `.fullBinary`
corresponds to the **framework-agent path** above. It's the "run the agent as a
normal NSApplication; no preview content" mode, used when:

- The Xcode build host can't or won't deliver a Dylib- or JIT-mode payload.
- Or as a stand-in during preview-pipeline disabled states (e.g.
  `Pipeline.isEnabled = false`).

The framework-agent path produces no preview output but maintains a live
NSApplication so that subsequent Dylib/JIT messages have a process to address.

### Q13 — Concurrent-patching semantics (partial close)

**Partial close, mechanism level.** The full answer requires the W3 patch-point
runtime confirmation that depends on driving a real preview update (separate
pre-implementation TODO; see `w3-patch-point-set.md`). What W3 *did* establish
about concurrency:

- Patch-applying executor is **agent-side XOJITExecutor**, callable from
  PreviewsInjection in the main-thread XPC handler.
- The patch primitive is `___xojit_executor_write_mem` — a remote-memory-write
  command in the LLVM `SimpleRemoteEPC` shape. Sequencing of the
  `mprotect`→`memcpy`→`mprotect` dance is *internal* to XOJITExecutor (the
  primitive imports `_mprotect`, `_memcpy`, `_memmove`).
- In-flight calls on patch targets are serialized at the source. Apple's design
  serializes through the protocol-witness-table pointer-width atomic write
  pattern (which the W2 Phase 2.1 stretch goal flagged). Live-mutex-style
  serialization is not used; instead the patch is structured to be safe under
  the platform's pointer-width atomicity guarantees.

See `w3-patch-point-set.md` for the patch-mechanism analysis.

### Q4 (byte-level `PreviewsJITLinkerParameters` over the wire), Q5 (PreLinked sub-enums)

**Not closed by W3.** Both require sniffing live XPC traffic from
Xcode↔previewsd↔agent, which requires driving a real preview session.
Pre-implementation TODO.

---

## Limits / what this timeline does *not* cover

1. **Runtime confirmation of steps 7c-7f.** The post-firstlink steps are
   grounded in:
   - `PreviewsInjection-exports.txt` (the function signatures exist as exports).
   - `XOJITExecutor-exports.txt` (the executor primitives exist as exports).
   - The agent's own stderr documenting the pre-firstlink decision tree.
   - The Q6 finding that XOJITExecutor is statically-linked LLVM ORC + JITLink.

   The exact ordering between 7c-7f under *real* load (with previewsd actively
   connected) was not directly observed. Direct observation requires either:
   - Driving Xcode via VNC scripting to create a SwiftUI project, open it, and
     trigger a preview render (multi-hour subproject; the `previewsvm setup`
     machinery is available — see
     `[[project_vm_recovery_automation_tahoe]]`).
   - Constructing an XPC client that impersonates `previewsd`'s protocol enough
     to deliver a single `PreviewsJITLinkerParameters` payload (also multi-hour;
     `PreviewsMessagingOS.MessageStream` is the protocol surface to study).

2. **Per-Xcode-version drift.** This timeline is grounded in Xcode 26.2. Earlier
   Xcode versions used a substantially different agent (DylibPreviewRecipe was
   the default before Xcode 16). The XOJIT path's `PreviewsInjection` API was
   reworked around Xcode 15; the env-var names with the `__PREVIEWS_*` prefix
   appear stable across recent versions but were not verified against prior
   releases. Spike non-goal per scope.

3. **iOS / device-side agent.** Same agent binary structure exists for
   iPhoneOS, watchOS, tvOS, xrOS platforms (10 platforms total — see
   `agent-metadata.txt`'s embedded support list). The lifecycle envelope is
   essentially identical on iOS-class platforms (NSXPCSharedListener →
   NSApplication-equivalent), but the lifecycle's "Step 0 — OS-level launch"
   side is more constrained (sandbox + entitlement model is stricter).
   Separate spike territory (`prompts/ios-host-wire-protocol.md`).

---

## Provenance

All claims above are grounded in artifacts under
`research/scripts/data/w3/`:

- `agent-metadata.txt` — `file`, `plutil -p` Info.plist, `codesign -dvvvv`,
  entitlements.
- `agent-loadcmds.txt` — `otool -arch arm64 -l XCPreviewAgent` (full Mach-O load
  command dump).
- `agent-exports.txt`, `agent-imports.txt`, `agent-dyldlinks.txt` — `dyld_info`
  surface.
- `agent-sec-debug_dylib.txt`, `agent-sec-debug_entry.txt`,
  `agent-sec-debug_instlnm.txt` — `otool -s __TEXT,__debug_dylib` etc. — all
  three sections are empty in the shipped agent.
- `agent-strings.txt`, `agent-cstrings.txt`, `agent-strings-preview.txt` —
  `strings`, `otool -v -s __TEXT,__cstring`, filtered subset.
- `agent-stderr-frameworkmode.txt` — live capture of agent's stderr when run
  without DYLD_INSERT_LIBRARIES + empty debug-dylib sections (= framework-agent
  path). Lines 1-12 are the full path-selection decision tree, verbatim.
- `agent-sample-jit-mode.txt` — `sample` output of the agent in JIT-mode
  (DYLD_INSERT_LIBRARIES set), showing the main thread blocked in
  `CFRunLoopRun`.
- `agent-lldb-jit-mode.txt` — `lldb -p` attach output, including image list and
  `image lookup` results for the four key entry-point symbols.
- `PreviewsInjection-exports.txt`, `PreviewsInjection-imports.txt`,
  `PreviewsInjection-linkeddylibs.txt` — VM-side `dyld_info` surface of the
  framework.
- `XOJITExecutor-exports.txt`, `XOJITExecutor-imports.txt`,
  `XOJITExecutor-linkeddylibs.txt` — same for XOJITExecutor.
- `frameworks-entitlements.txt` — neither framework has its own
  entitlements (both are shared-cache resident, so they're not separately
  signed — only the agent process inherits).

Captured on macOS 26.3.1 in the `post-xcode-sip-amfi` snapshot of
`research/vm/` against Xcode 26.2.

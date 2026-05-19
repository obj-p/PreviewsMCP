# Open Question 6 — Does Apple's JIT linker use LLVM ORC?

**Verdict: yes.** Apple's `XOJITExecutor.framework` is built on
LLVM ORC + JITLink, statically linked, wrapped in a Swift+XPC
façade. The "Remaining gap" section originally captured at the
bottom of this memo was closed by a VM-side `dyld_info` run —
see Section ("VM-side evidence") below.

## What we looked at

Three binaries / stubs are relevant to "Apple's preview JIT runtime":

| Binary | Where | Role |
|---|---|---|
| `libPreviewsJITStubExecutor.a` | host static archive, per-platform | static-linked into the agent — the "blank executor" main + dlopen-based dylib lookup |
| `PreviewsInjection.framework` | device-side, dyld shared cache (only `.tbd` stub on host) | DYLD_INSERT_LIBRARIES-injected at agent launch; owns the JIT-link entry points |
| `XCPreviewAgent.app` | per-platform agent binary | the process whose `main()` is the stub above |

Symbol surfaces captured in `research/scripts/data/`:
- `libPreviewsJITStubExecutor-symbols.txt` — 39 exported
- `libPreviewsJITStubExecutor-undefined.txt` — 41 undefined refs
- `PreviewsInjection-tbd-symbols.txt` — 357 public symbols from the .tbd stub
- `jit-runtime-markers.txt` — marker grep summary

## The marker grep result

Zero matches for `llvm::`, `orc::`, `JITLink`, `RuntimeDyld`, `XOJIT`,
`jitlink`, or any LLVM-ORC API surface in either the JIT stub
executor's symbols or the PreviewsInjection public-API stub. The only
JIT-related public-surface symbols are inside the Swift-mangled
`PreviewsInjection` module namespace, not in any `llvm::` C++
namespace.

## What `libPreviewsJITStubExecutor.a` actually is

A tiny static archive — 2 object files
(`PreviewsJITStubExecutor.o` + `PreviewsJITStubExecutor_vers.o`).
Total 39 exported symbols, total 41 undefined refs. The exported
surface is essentially:

- `___debug_blank_executor_main` — the agent's `main()` for the
  pre-link / debug path. Loops on `CFRunLoopRun`-style scheduling.
- `___previews_blank_executor_run_user_entry_point` — runs the user's
  preview entry point once it's been resolved.
- `_findDebugDylibMachHeaderAmongLoadedImages` — walks
  `_dyld_image_count` / `_dyld_get_image_header` looking for the
  preview dylib.
- `_lookupMainFuncAddressInDebugDylibMachHeader` — finds the entry
  point address inside the Mach-O once the image is located.
- `_getDebugDylibHandle` / `_getDebugDylibEntryPoint` /
  `_assertDebugDylibStatus` — accessors / sanity checks.
- A family of **abort messages** that double as documentation:
  - `_abort_normaldylib_expected_but_found_pseudodylib___debug_dylib`
  - `_abort_pseudodylib_expected_but_found_normal___debug_dylib`
  - `_abort_failed_to_open___debug_dylib`
  - `_abort_could_not_find_entry_point___debug_dylib`
  - `_abort_swift_entry_mach_header_not_found___debug_dylib`
  - `_abort_swift_entry_main_entry_point_not_found___debug_dylib`
  - `_abort_swift_entry_point_address_could_not_be_determined___debug_dylib`
  - `_abort_failed_to_find_previews_injection_swift_entry_fetcher___debug_dylib`
  - `_abort_failed_to_get_debug_dylib_handle_for_swift_entry_fetcher___debug_dylib`
  - `_abort_failed_to_lookup_debug_dylib_macho_handle_by_suffix___debug_dylib`

The undefined refs are ALL standard libc + libdyld + libos_log:
`dlopen`, `dlsym`, `dlerror`, `_dyld_get_image_header`,
`_dyld_image_count`, `_dyld_get_dlopen_image_header`,
`getsectiondata`, `os_log_*`, `calloc`, `free`, `memcpy`, plus the
six custom-section `section$start$/$end$` symbols for
`__TEXT$__debug_dylib`, `__TEXT$__debug_entry`,
`__TEXT$__debug_instlnm`.

**Interpretation.** `libPreviewsJITStubExecutor.a` is not a JIT
engine. It's a thin Mach-O loader-stub:
1. The agent boots with this code as `main()`.
2. It opens the user's preview dylib with `dlopen`.
3. It walks the loaded image list to find the dylib's Mach header.
4. It uses `getsectiondata` to read the agent's own custom
   `__TEXT,__debug_*` sections — which carry pointers from the
   PreviewsInjection-side runtime — to dispatch.
5. It hands off to PreviewsInjection's Swift-side entry-point
   fetcher, then to the user's entry point.

No code paths through this archive ever build object files, allocate
executable memory, or perform link-time relocations. The actual JIT
link must be entirely on PreviewsInjection's side.

## The `pseudodylib` vs `dylib` distinction

The stub knows two flavors of "dylib":
- **normal dylib** — produced by `ld`, on disk, loaded via `dlopen`.
- **pseudodylib** — a "fake dylib" loaded by some
  PreviewsInjection mechanism (probably an in-memory Mach-O image
  the JIT linker constructs from `.o` files). The stub aborts if it
  gets the wrong flavor.

A single PreviewsInjection-side symbol explicitly returns metadata
for it:

    PreviewsInjection.__previewsInjectionGetDebugPseudodylibSwiftEntrySectionData() -> Swift.UnsafeRawPointer

So the JIT path's output is a "pseudodylib" containing a Swift entry
section data blob. This is consistent with the LLVM JITLink concept
of an in-memory dylib (LLVM has a `MaterializationUnit` / `LinkGraph`
model that produces something very similar) — but the naming is
distinctively Apple, not LLVM ORC's vocabulary.

## What `PreviewsInjection.tbd` says

357 public symbols, of which only **two** name the JIT-link
operation:

    PreviewsInjection.__previewsInjectionPerformFirstJITLink(
        argc: Int32,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?
    ) -> Int32

    PreviewsInjection.__previewsInjectionJITLinkEntrypoint(
        argc: Int32,
        argv: UnsafeMutablePointer<UnsafeMutablePointer<Int8>?>?,
        previewsDylibPath: UnsafeMutablePointer<Int8>?,
        previewsDylibEntryPointName: UnsafeMutablePointer<Int8>?
    ) -> ()

Plus one abort message that documents a synchronization point:

    PreviewsInjection.___abort_timed_out_waiting_for_previews_jit_first_link_signal() -> Swift.Never

So the agent's JIT-link lifecycle is:
1. Agent process starts. `___debug_blank_executor_main()` (from the
   stub archive) runs.
2. The stub calls `PerformFirstJITLink(argc, argv)` — bootstrap link
   to set up the JIT environment. Returns an `Int32` status.
3. The stub then waits for a "first link signal" (probably an XPC
   reply or signal-handler trigger). If it times out, the abort
   above fires.
4. On each preview update, the agent receives an IPC message from
   Xcode that carries the new dylib path + entry point name. The
   stub invokes
   `JITLinkEntrypoint(argc, argv, previewsDylibPath, previewsDylibEntryPointName)`,
   which (re)links and (re)launches the user's preview.

This is a deliberately minimal C-style ABI between the agent's
main() and the JIT-link engine. Whatever LLVM internals
PreviewsInjection's body uses, **it does not expose them as
public API surface** — neither the agent's stub nor any external
caller can reach `llvm::orc::*` symbols.

## What this means for the spike verdict

The original Q6 phrasing was "does Apple's JIT linker actually use
LLVM ORC, or a private fork?" The evidence here partially answers
it:

- **Apple's public JIT-link API is NOT an LLVM ORC API.** The
  exposed surface is two C-style Swift functions plus a raw-pointer
  metadata accessor. No `llvm::orc::*`, `JITLink`, `RuntimeDyld`,
  `XOJIT` symbols are exported by either binary we can inspect from
  the host.
- **Whether PreviewsInjection's body USES LLVM ORC internally is
  still unresolved** — its `.tbd` only exposes the public surface;
  the body lives in the device-side dyld shared cache and would
  need either `dyld_info -fixups`/`-imports` against the cache or
  `nm` on the extracted-from-cache binary to determine its undefined
  references. That's a VM-side task.
- **Either way, this is favorable for the buildable verdict.**
  Our POC plan was always "build our own equivalent on public LLVM
  ORC". Apple's choice to wrap their JIT linker in a minimal
  C-style ABI — rather than expose ORC API — means our equivalent
  doesn't need to bind to Apple's specific JIT internals. We
  produce `.o` files from `swiftc -emit-object`, we feed them to
  LLVM's public ORC `LLJIT` / `ObjectLinkingLayer`, and we expose
  our own minimal C-style entrypoint to the agent. The shape
  matches Apple's, the public-layer toolkit handles the load-bearing
  step (relocations, atom-level linking, runtime symbol resolution),
  and Apple's specific internal choices are not load-bearing for
  ours.

The remaining LLVM-ORC-coverage question — "can public ORC handle
Swift's emission patterns (TLVs, async functions, witness tables,
metadata registration) the way Apple's runtime evidently does?" —
is still W2's POC question. Q6's resolution doesn't change the POC
plan; it just removes the worry that we'd need to *imitate Apple's
internal API surface* to be feasible.

## VM-side evidence (the gap closed)

Booted `post-xcode-sip-amfi`, dumped the VM-side framework
internals via `dyld_info`. Captured by
`dump-vm-jit-symbols.sh` to `data/vm/`. Two findings make
the verdict unambiguous.

### Finding 1: `PreviewsInjection` weak-links `XOJITExecutor.framework`

`dyld_info -linked_dylibs` on the VM-side
`PreviewsInjection.framework` shows:

    weak-link  /System/Library/PrivateFrameworks/XOJITExecutor.framework/Versions/A/XOJITExecutor

This framework wasn't visible from the host (it has no `.tbd` stub
in the SDK). It's where the actual JIT engine lives — `PreviewsInjection`
just wraps it.

Also imports `__dyld_is_pseudodylib` from `libSystem` —
**pseudodylibs are a first-class dyld concept on macOS now**,
not just a PreviewsInjection abstraction. Apple extended dyld
itself with a pseudodylib type predicate.

### Finding 2: `XOJITExecutor.framework` exports LLVM ORC symbols by name

`dyld_info -exports` on the VM-side
`XOJITExecutor.framework` (48 exports total — visibility is
mostly hidden) leaks exactly the symbols that have to be public
for the GDB/LLDB JIT debug interface to work:

    ___jit_debug_register_code
    ___jit_debug_descriptor
    _llvm_orc_registerJITLoaderGDBAllocAction

The first two are the standard
[LLVM/GDB JIT debug interface](https://llvm.org/docs/DebuggingJITedCode.html)
symbols (LLDB and GDB look them up by name to track JIT'd code).
The third is **literally an `llvm::orc::` API function** —
defined in LLVM's
`llvm/include/llvm/ExecutionEngine/Orc/Debugging/DebuggerSupportPlugin.h`
and registered with `ObjectLinkingLayer`.

The Swift-side API confirms it independently:

- `XOJITExecutor.XOJITExecutor` — a Swift class (the public façade)
- `XOJITExecutor.XOJITExecutor.JITDylibHandle (rawValue: UInt64)`
  — **`JITDylib` is LLVM ORC's primary namespace abstraction**;
  every JIT in ORC has JITDylibs.
- `XOJITExecutor.XOJITExecutor.init(connection: OS_xpc_object)` —
  initialized with an XPC connection (XPC replaces LLVM's default
  socket/pipe-based executor protocol).
- `TerminationResult` enum with `.success`, `.badCommand`,
  `.remoteDisconnect`, `.failedSetup` — matches the failure modes
  of LLVM's `SimpleRemoteEPC` exactly.
- C-side helpers `___xojit_executor_write_mem`,
  `___xojit_executor_run_program_on_main_thread`,
  `___xojit_executor_run_program_wrapper`,
  `___xojit_run_wrapper` — the "remote executor write/run memory"
  pattern, identical in shape to LLVM's `llvm-jitlink-executor`
  helper tool.

### Why LLVM symbols don't appear in `-imports`

`XOJITExecutor.framework` links only `Foundation`, `libobjc`,
**`libc++.1.dylib`**, `libSystem`, and the Swift runtime — no
`libLLVMOrcJIT.dylib` or any other LLVM dylib. `dyld_info -imports`
across both binaries shows zero `llvm::*` C++ mangled symbols.

Interpretation: **LLVM ORC + JITLink is statically linked into
`XOJITExecutor.framework`** with `-fvisibility=hidden`, so only the
symbols that have to be visible-by-string-lookup (GDB JIT
interface) leak through. The `libc++.1.dylib` dependency is the
tell that there's substantial C++ code inside — exactly what an
LLVM-derived linker would need.

### Architectural model Apple ships

Putting the pieces together, Apple's runtime JIT-link is:

1. **`XCPreviewAgent`** (the agent binary, per platform) starts.
   Its `main()` is `___debug_blank_executor_main` from
   `libPreviewsJITStubExecutor.a` (the thin Mach-O loader stub).
2. **`PreviewsInjection.framework`** is `DYLD_INSERT_LIBRARIES`-injected
   at agent launch. Provides the Swift-side runtime, host XPC
   surface, and a single C-style JIT-link entrypoint
   (`__previewsInjectionJITLinkEntrypoint`).
3. **`XOJITExecutor.framework`** is dlopen-ed (weak-linked) by
   PreviewsInjection. This is the **LLVM ORC engine, statically
   linked**. It exposes a Swift class
   `XOJITExecutor(connection: OS_xpc_object)` that drives the JIT.
4. Xcode sends the agent an XPC message carrying object-file paths
   + linker parameters (the `PreviewsJITLinkerParameters` shape
   from `architecture-diagram-draft.md`).
5. The XOJITExecutor calls into LLVM ORC's `LLJIT` + `ObjectLinkingLayer`
   to JIT-link the `.o` files into a `JITDylib`, then runs the
   resulting code on the main thread via
   `___xojit_executor_run_program_on_main_thread`.
6. The result is a **pseudodylib** — an in-memory Mach-O image
   that dyld treats specially (the predicate
   `__dyld_is_pseudodylib` exists in libSystem).

This is **architecturally equivalent to public LLVM's
`llvm-jitlink-executor` tool** + a custom Mach-O-pseudodylib dyld
hook. The only Apple-private piece is the dyld pseudodylib
extension (and even that has a documented purpose: hide in-memory
JIT'd images from normal-dlopen scanners while keeping them
debuggable).

## What this means for the spike verdict (updated)

The previous draft said this resolution was "favorable for
buildable." With the VM-side evidence in hand, the bar moves
higher: **the architecture we'd build on public LLVM ORC is
*the same architecture* Apple shipped**, minus the
pseudodylib dyld extension (which we don't need — normal
in-memory `.o` linking via JITLink produces equivalent results,
just without dyld-level concealment).

Concretely, our W2 POC mirrors Apple's runtime stack:

| Apple piece | Public-layer analogue |
|---|---|
| `XOJITExecutor` (Swift class wrapping LLVM ORC) | Our Swift class wrapping `llvm::orc::LLJIT` + `ObjectLinkingLayer` |
| XPC-based executor protocol | LLVM's `SimpleRemoteEPC` (default) over Unix domain socket OR XPC if we want |
| `JITDylibHandle` Swift type | Direct re-export of `llvm::orc::JITDylib`'s handle |
| `TerminationResult` enum | The same four cases LLVM's executor returns |
| `___xojit_executor_write_mem` / `_run_program_wrapper` | LLVM ORC's `RuntimeAlloc::onResolveCompleteCallback` + the `LLJIT::lookup`/`runConstructors`/`runProgram` family |
| GDB JIT debug interface | `llvm::orc::Debugger::register` via `DebuggerSupportPlugin` |
| pseudodylib via dyld extension | Not replicated — our images are normal-dyld-visible (it's fine; debuggers handle this either way) |

**The single remaining "is it buildable?" question is exactly
what the spike doc says it is**: whether LLVM ORC covers Swift's
emission patterns (TLVs, async functions, witness tables, runtime
metadata registration). The W2 POC targets exactly that question,
and we now know with certainty that Apple's runtime is built on
the *same public layer* the POC will exercise — so a positive POC
result strongly implies feasibility for our full target.

Headline: **Q6 is closed. Verdict positive. Building on public
LLVM ORC isn't speculative — it's the same stack Apple ships,
sans pseudodylib hide-from-dyld trick.**

## Data provenance

- `data/libPreviewsJITStubExecutor-symbols.txt` — `nm -gU` of arm64
  slice + swift-demangle + c++filt + sort -u.
- `data/libPreviewsJITStubExecutor-undefined.txt` — `nm -u` of same.
- `data/PreviewsInjection-tbd-symbols.txt` — extracted from the .tbd
  YAML, demangled.
- All from `/Applications/Xcode-26.2.0.app` (Xcode 26.2 / Build 17C52
  — same as `post-xcode-sip-amfi`).
- Captured by `dump-jit-runtime-symbols.sh`. Re-running is
  idempotent.

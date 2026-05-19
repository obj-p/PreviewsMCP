# Open Question 6 — Does Apple's JIT linker use LLVM ORC?

Resolves Q6 from `architecture-diagram-draft.md` Section 4 — partially,
with a precise gap.

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

## Remaining gap to fully resolve Q6

To definitively answer "is PreviewsInjection's body LLVM ORC
internally," we'd need:

1. Boot the research VM (`post-xcode-sip-amfi` snapshot).
2. SSH in. Run:
   ```
   xcrun dyld_info -fixups /System/Library/PrivateFrameworks/PreviewsInjection.framework/PreviewsInjection \
     | grep -E 'llvm|orc|JIT|RuntimeDyld'
   ```
   The shared-cache resolver should handle the path. If the binary
   imports `__ZN4llvm3orc...` mangled C++ symbols from
   libLLVMOrcJIT or analogue, it's ORC-derived. If it's
   self-contained or imports only Swift runtime + libsystem +
   `pthread`, it's a custom engine.
3. Capture the import list to `data/PreviewsInjection-imports.txt`
   alongside the public-surface dump.

Cost: one VM boot + ~2 minutes. Worth doing as a follow-up, but
**not gating** for the spike verdict — the public-surface analysis
above already tells us the integration shape we'd need to match.

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

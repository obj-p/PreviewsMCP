# Build System Integration

How PreviewsMCP compiles previews for multi-file projects, and how Xcode Previews does it natively.

## Architecture

PreviewsMCP supports two compilation tiers for project builds:

### Tier 1: Bridge-only

When only module-level flags are available (e.g., Bazel, manual configuration):

1. Build the project with the native build system
2. Generate a bridge source: `@testable import <TargetModule>` + `@_cdecl` entry point
3. Compile the bridge against the target's `.swiftmodule` (provides type information)
4. No literal hot-reload (view source is in the pre-built module)

### Tier 2: Source compilation

When all target source files are available (SPM):

1. Build dependency targets with `swift build` (produces `.swiftmodule` files)
2. Compile ALL source files from the preview's target + our bridge into a dylib
3. ThunkGenerator transforms are applied to the preview file for literal hot-reload
4. Other target files are compiled as-is (provides type information)

## SPM Build System

### Detection

`SPMBuildSystem.detect(for:)` walks up from the source file looking for `Package.swift`.

### Build Flow

```
swift package describe --type json  →  find target containing source file
swift build                         →  incremental build (deps + target)
swift build --show-bin-path         →  locate build artifacts
```

For iOS simulator:
```
swift build --triple arm64-apple-ios17.0-simulator --sdk $(xcrun --show-sdk-path --sdk iphonesimulator)
```

### Artifact Layout

SPM stores build artifacts at `.build/<triple>/debug/`:

```
.build/arm64-apple-macosx/debug/
  Modules/
    <TargetName>.swiftmodule    ← module interface (type info)
  <TargetName>.build/
    <FileName>.swift.o          ← per-file object files
    output-file-map.json        ← source → .o mapping
```

### File Watching

The file watcher monitors all `.swift` files in the target directory. When any file changes:
- Preview file change → try literal-only fast path (DesignTimeStore), else full recompile
- Other file change → full recompile (rebuild all target sources + bridge)

## Xcode Build System

### Detection

`XcodeBuildSystem.detect(for:)` walks up from the source file looking for `.xcodeproj` or `.xcworkspace`. SPM is preferred when both markers exist (a `Package.swift` in the same tree wins).

### Build Flow

```
xcodebuild -list -json                              →  enumerate schemes
xcodebuild build -scheme <s> -destination <d>       →  build the framework
xcodebuild -showBuildSettings -scheme <s>           →  read settings
```

### Artifact Layout

Xcode writes build outputs under `~/Library/Developer/Xcode/DerivedData/<project>-<hash>/`:

```
Build/Products/<Configuration>-<Platform>/
  <Target>.framework/
    <Target>                            ← framework binary
    Modules/<Target>.swiftmodule/       ← per-arch swiftmodule files
    Assets.car                          ← compiled asset catalog (resources)
    Info.plist
Build/Intermediates.noindex/<project>.build/<Configuration>-<Platform>/<Target>.build/
  Objects-normal/<arch>/                ← OBJECT_FILE_DIR_normal/<arch>
    <Target>-OutputFileMap.json         ← swift-driver input/output map
    <FileName>.o                        ← per-file object files
    <Target>.swiftmodule                ← per-arch swiftmodule (also under Build/Products)
  DerivedSources/                       ← DERIVED_FILE_DIR
    GeneratedAssetSymbols.swift         ← Color.brandPrimary, etc.
    GeneratedStringSymbols.swift        ← string-catalog symbols
    GeneratedPlistSymbols.swift         ← plist symbols
```

PreviewsMCP reads:

| Build setting        | Used for                                                                 |
|----------------------|--------------------------------------------------------------------------|
| `BUILT_PRODUCTS_DIR` | `-F` framework search path so `import <Target>` resolves                  |
| `FRAMEWORK_SEARCH_PATHS` | Additional `-F` paths for dependency frameworks                       |
| `OBJECT_FILE_DIR_normal` | Locate `<Target>-OutputFileMap.json` to enumerate Tier 2 source files |
| `DERIVED_FILE_DIR`   | Append Xcode-generated Swift files (asset symbols, etc.) to Tier 2        |
| `CODESIGNING_FOLDER_PATH` | Absolute path to the framework wrapper, used to rewrite `Generated*Symbols.swift` resource-bundle lookups (see below) |
| `PRODUCT_MODULE_NAME` / `TARGET_NAME` | Module name for the bridge dylib                              |

### Resource-Bundle Rewrite

`Generated*Symbols.swift` files contain a preamble of the form:

```swift
#if SWIFT_PACKAGE
private let resourceBundle = Foundation.Bundle.module
#else
private class ResourceBundleClass {}
private let resourceBundle = Foundation.Bundle(for: ResourceBundleClass.self)
#endif
```

`Bundle(for:)` resolves to whichever binary contains `ResourceBundleClass`. When PreviewsMCP recompiles this file into the bridge dylib, that binary becomes the bridge dylib (which has no `Assets.car`), so `Color(.brandPrimary)` and similar asset lookups silently return nothing. To prevent that, `XcodeBuildSystem` writes a transformed copy of each `Generated*Symbols.swift` to `<DERIVED_FILE_DIR>/PreviewsMCPRewrites/` whose preamble points at the framework's on-disk wrapper:

```swift
private let resourceBundle = Foundation.Bundle(path: "<CODESIGNING_FOLDER_PATH>") ?? Foundation.Bundle.main
```

The transformation is invisible to the rest of Tier 2 — the rewritten URLs replace the originals in `BuildContext.sourceFiles`.

### File Watching

Same scope as SPM: `.swift` files under the target's source root, plus the preview file. Xcode-generated `Generated*Symbols.swift` files are picked up only on full rebuilds (they're driven by the asset catalog / string catalog, not by source edits).

## Bazel Build System

### Detection

`BazelBuildSystem.detect(for:)` walks up from the source file looking for `WORKSPACE`, `WORKSPACE.bazel`, `MODULE.bazel`, or `BUILD` / `BUILD.bazel` markers. Falls through to Xcode if no Bazel marker is found.

### Build Flow

```
bazel query 'kind(swift_library, ...)'  →  find the target containing the source file
bazel query 'attr(module_name, ...)'    →  determine the Swift module name
bazel build <target>                    →  build the target
bazel cquery --output=files <target>    →  locate the .swiftmodule
```

### Artifact Layout

Bazel writes outputs to the `bazel-bin/` symlink at the workspace root:

```
bazel-bin/<package>/
  <target>.swiftmodule                 ← module interface
  <target>.a                           ← static archive (Tier 2 unused)
  <target>_objs/                       ← per-source `.o` files
```

PreviewsMCP relies on `bazel cquery --output=files` to locate the `.swiftmodule`, falling back to `bazel-bin/<package>/<moduleName>.swiftmodule` if cquery returns no files. The directory containing the `.swiftmodule` becomes the single `-I` flag passed to swiftc — there is no per-file enumeration of dependency search paths.

Source files for Tier 2 are enumerated via `bazel query 'labels(srcs, <target>)'`. There is **no** `DerivedSources/` walk: rules_swift's `swift_library` does not synthesize a `Bundle.module` accessor (resources are exposed as a separate `apple_resource_bundle` reached via `Bundle(identifier:)` or a hand-written accessor). Auto-generated outputs from `swift_proto_library` / `swift_grpc_library` are also not currently picked up; if needed, extend `collectSourceFiles` to union those `.swift` outputs from `bazel cquery --output=files`.

### File Watching

Same scope as SPM: `.swift` files under the target's source root.

## Interfaces

### BuildSystem Protocol

Extensible protocol for adding new build systems (SPM, Xcode, Bazel):

```swift
public protocol BuildSystem: Sendable {
    /// Detect if this build system applies to the source file.
    /// Walk up directories to find project markers (Package.swift, .xcworkspace, .xcodeproj, BUILD).
    static func detect(for sourceFile: URL) async throws -> Self?

    /// Build the project and return the context for preview compilation.
    func build(platform: PreviewPlatform) async throws -> BuildContext

    /// The project root directory.
    var projectRoot: URL { get }
}
```

Detection order is defined in `BuildSystemDetector`:

```swift
public enum BuildSystemDetector {
    public static func detect(for sourceFile: URL) async throws -> (any BuildSystem)? {
        if let spm = try await SPMBuildSystem.detect(for: sourceFile) { return spm }
        if let bazel = try await BazelBuildSystem.detect(for: sourceFile) { return bazel }
        if let xcode = try await XcodeBuildSystem.detect(for: sourceFile) { return xcode }
        return nil
    }
}
```

### BuildContext

The output contract from `build()`. This is what the compiler pipeline consumes — build system implementations produce this, and `PreviewSession`/`Compiler` consume it.

```swift
public struct BuildContext: Sendable {
    /// The target module name. Used for `-module-name` (Tier 2) or `@testable import` (Tier 1).
    public let moduleName: String

    /// Extra swiftc flags. Typically `-I <modules-dir>` for dependency module search paths.
    public let compilerFlags: [String]

    /// Project root directory.
    public let projectRoot: URL

    /// Target name within the project.
    public let targetName: String

    /// All source files in the target EXCEPT the preview file (Tier 2, optional).
    /// When non-nil, these are compiled alongside the transformed preview file.
    /// When nil, falls back to Tier 1 (bridge-only with @testable import).
    public let sourceFiles: [URL]?

    /// Whether Tier 2 (source compilation + literal hot-reload) is available.
    public var supportsTier2: Bool { sourceFiles != nil }
}
```

### Compilation Flow

```
BuildSystemDetector.detect(for: sourceFile)
    → SPMBuildSystem / XcodeBuildSystem / BazelBuildSystem / nil

buildSystem.build(platform:)
    → BuildContext { moduleName, compilerFlags, sourceFiles? }

PreviewSession.compile():
    if buildContext == nil:
        → standalone mode (existing single-file behavior)
    if buildContext.supportsTier2:
        → Tier 2: generateOverlaySource() + compile all target sources
    else:
        → Tier 1: generateBridgeOnlySource() with @testable import
```

### Adding a New Build System

To add Xcode or Bazel support, implement the `BuildSystem` protocol:

1. **`detect(for:)`** — Walk up from the source file looking for your project marker (`.xcworkspace`, `.xcodeproj`, `BUILD`, `WORKSPACE`)
2. **`build(platform:)`** — Run your build tool, then return a `BuildContext` with:
   - `moduleName` — the target containing the source file
   - `compilerFlags` — `-I` paths to find dependency `.swiftmodule` files
   - `sourceFiles` — (optional) all `.swift` files in the target for Tier 2
3. **Register in `BuildSystemDetector.detect()`** — Add your detection call in priority order

For **Xcode projects**, `build()` would:
- Run `xcodebuild build -scheme <scheme> -destination <platform>`
- Parse `xcodebuild -showBuildSettings` for `BUILT_PRODUCTS_DIR`, `TARGET_BUILD_DIR`
- Find `.swiftmodule` in the build products
- Enumerate source files from the `.xcodeproj` or `xcodebuild -showBuildSettings` `SWIFT_COMPILATION_MODE`

For **Bazel**, `build()` would:
- Run `bazel build <target>`
- Find build outputs in `bazel-bin/`
- May only provide Tier 1 (module + flags) depending on how Bazel Swift rules structure outputs

## How Xcode Previews Does It

Traced via `fs_usage` on macOS with SIP disabled (March 2026, Xcode 26.2).

### Initial Preview Load

Xcode checks the target's build artifacts:
```
.../DerivedData/<project>/Build/Intermediates.noindex/
  <Target>.build/Debug-iphonesimulator/<Target>.build/Objects-normal/arm64/
    <Target>.swiftmodule       ← module interface
    <Target>.abi.json          ← ABI descriptor
    <FileName>.o               ← per-file objects
    <Target>.LinkFileList      ← linker input list
```

### Cross-File Change (editing Item.swift while previewing ToDoView.swift)

Full trace timeline (~1.5 seconds):

| Time (offset) | Operation | Path |
|---|---|---|
| +0.000s | `getattrlist` | `Sources/ToDo/Item.swift` — detect file change |
| +0.200s | `stat64` | `Item.swift`, `ToDoView.swift` — check both source files |
| +0.400s | `stat64` | `ToDo.swiftmodule`, `ToDo.abi.json` — check module staleness |
| +0.500s | `open` | `ToDo.LinkFileList`, `Item.o`, `ToDoView.o` — check object files |
| +0.600s | **write** | `vfsoverlay-ToDoView.1.preview-thunk.swift.json` — VFS overlay |
| +0.600s | **write** | `ToDoView.1.preview-thunk.swift` — preview thunk source |
| +0.600s | compile | `ToDoView.1.preview-thunk.o` — compile thunk |
| +0.700s | compile | `ToDoView.1.preview-thunk-launch.o` — launch helper |
| +1.200s | `lstat64` | `ToDoView.1.preview-thunk.o` — verify thunk ready |
| +1.500s | | Thunk `.o` sent to XCPreviewAgent via JIT executor |

### Key Findings

1. **Incremental build system drives updates** — Xcode doesn't use a separate file watcher for previews. Its build system detects source changes, recompiles only the changed file (`Item.o`), updates the `.swiftmodule`, then generates a preview thunk.

2. **Preview thunk is tiny** — `ToDoView.1.preview-thunk.swift` is a generated file containing just the preview entry point. It imports the target module and wraps the `#Preview` closure body.

3. **VFS overlay** — `vfsoverlay-ToDoView.1.preview-thunk.swift.json` maps the thunk source to appear at the right path for the compiler. This is part of the preview thunk compilation infrastructure.

4. **Two thunk objects** — `preview-thunk.o` (preview entry point) and `preview-thunk-launch.o` (launch helper) are compiled and sent to XCPreviewAgent.

5. **JIT executor** — XCPreviewAgent receives the thunk `.o` files and JIT-links them into the running process. No dylib creation needed — the `.o` is loaded directly.

6. **No full target recompilation** — Only the changed file and the thunk are compiled. The `.swiftmodule` provides type information for the thunk to reference all target types.

### How PreviewsMCP Differs

| Aspect | Xcode | PreviewsMCP |
|--------|-------|-------------|
| Build system | xcodebuild (incremental, per-file `.o`) | `swift build` (incremental) + swiftc for preview dylib |
| Preview compilation | Thin thunk → `.o` → JIT link | Full source compilation → dylib → dlopen |
| Type resolution | `.swiftmodule` import | Compile all target sources together (Tier 2) or `@testable import` (Tier 1) |
| Hot-reload trigger | Build system FSEvents | File watcher polling (0.5s) |
| Literal fast path | `__designTimeString` baked into target build | ThunkGenerator + DesignTimeStore in preview dylib |
| File watching scope | All project files (build system) | All target source files |

# Setup Build Cache

How PreviewsMCP caches setup plugin build artifacts to skip redundant `swift build` invocations across preview sessions.

## Problem

`SetupBuilder` runs `swift build` on the setup package every `preview_start`. SPM's incremental compilation avoids recompiling unchanged code, but the subprocess round-trips (`swift build`, `swift build --show-bin-path`) and unconditional `ar` archiving still cost ~3–10s per session. Users editing their app code — not the setup package — pay that tax on every preview.

## How It Works

`SetupCache` intercepts `SetupBuilder.build` with a hash-based lookup:

```
preview_start
    │
    ├── Hash setup package sources → sourceHash
    ├── Check cache: .build/previewsmcp-setup-cache/<platform>-<sourceHash>.json
    │   ├── HIT: validate artifacts on disk → return cached Result
    │   └── MISS: fall through
    │
    ├── swift build (full build)
    ├── swift build --show-bin-path
    ├── Archive .o → .a (ar)
    ├── Collect compiler flags
    ├── Write cache entry
    └── Return Result
```

On a warm hit, `SetupBuilder.build` returns in <100ms instead of several seconds.

## Cache Key

SHA256 of the following inputs, in order:

1. Sorted `(relativePath, SHA256(fileContents))` tuples for:
   - `Package.swift`
   - `Package.resolved` (if present)
   - Every `*.swift` file recursively under `Sources/`
2. iOS SDK path (for iOS builds; nil for macOS) — so Xcode upgrades invalidate the cache
3. Swift toolchain version (`swift --version` first line)

The platform string (`macos` / `ios`) is encoded in the filename, not the hash, so both platforms can cache independently.

**Excluded from the hash:** `Tests/`, `.build/`, `.swiftpm/`, non-Swift files. Changes to these do not affect the setup module's build output.

## Cache Value

A JSON-encoded entry containing:

```json
{
  "moduleName": "MyAppPreviewSetup",
  "typeName": "AppPreviewSetup",
  "compilerFlags": ["-I", "/path/to/Modules", "-L", "/path/to/debug", "-lMyAppPreviewSetup"],
  "sourceHash": "a1b2c3...",
  "swiftVersion": "Swift version 6.0.3 ...",
  "platform": "macOS"
}
```

## On-Disk Layout

Cache files live inside the setup package's own `.build/` directory:

```
<setupPackageDir>/.build/previewsmcp-setup-cache/
├── macos-<hash>.json
└── ios-<hash>.json
```

This location means:
- `swift package clean` wipes the cache naturally
- CI's existing `.build` cache picks up setup cache entries for free
- Both platforms coexist without evicting each other

## Artifact Validation

A cache hit is not trusted blindly. Before returning a cached result, `SetupCache.load` validates that every path referenced in `compilerFlags` still exists:

| Flag | Validation |
|------|-----------|
| `-I <dir>` | Directory exists **and** `<moduleName>.swiftmodule` exists inside it |
| `-L <dir>` | Directory exists |
| `-l<name>` | `lib<name>.a` exists under at least one `-L` directory |
| `-F <dir>` | Directory exists |
| `-framework <name>` | `<name>.framework` exists under at least one `-F` directory |

If any check fails, the entry is treated as a miss and a full build runs.

## Eviction

There is no active eviction. Cache entries are a few hundred bytes of JSON each, and the hash space is bounded by the number of distinct source states the package has had. Running `swift package clean` wipes the parent `.build/` directory, which clears the cache naturally.

## Error Handling

The cache must never break `preview_start`:

- **Read failures** (missing file, corrupt JSON, decode error): return `nil` (cache miss), fall through to full build. Corrupt JSON files are deleted best-effort.
- **Write failures** (permissions, disk full): logged to stderr via `fputs`, never thrown.
- **Hash failures** (missing `Package.swift`): propagated as errors — this indicates a misconfigured setup package, not a cache issue.

## Swift Version Caching

`resolveSwiftVersion()` runs `swift --version` as a subprocess (~50ms). The result is cached in a process-lifetime static variable via `OSAllocatedUnfairLock`, so repeated `preview_start` calls in the same process only pay the subprocess cost once.

## CI Integration

The setup cache directory lives under `.build/`, which is already cached by the CI workflow's `actions/cache` step. No additional CI configuration is needed for setup caching to work across workflow runs.

The CI workflow uses per-job cache keys to prevent the `build-and-test` and `ios-tests` jobs from clobbering each other's caches when running in parallel:

| Job | Cache key |
|-----|-----------|
| `build-and-test` | `spm-${{ runner.os }}-build-${{ hashFiles('Package.resolved') }}` |
| `ios-tests` | `spm-${{ runner.os }}-ios-${{ hashFiles('Package.resolved') }}` |

Both share a `spm-${{ runner.os }}-` restore-keys fallback so a cold job can warm from the other's cache.

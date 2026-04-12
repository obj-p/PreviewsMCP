# Spec: SetupBuilder Artifact Cache + CI Cache Improvements

Tracking: [#81](https://github.com/anthropics/previewsmcp/issues/81)

## Objective

Reduce `preview_start` latency for projects that use a setup plugin by skipping redundant work inside `SetupBuilder`, and improve CI wall time by tightening the GitHub Actions cache configuration.

Today `SetupBuilder.build` runs `swift build`, then `swift build --show-bin-path`, then archives every target's `.o` files into `.a` libraries on every `preview_start`. SPM's own incremental avoids recompiling unchanged code, but the subprocess round-trips and the unconditional `ar` pass still cost ~3–10s per session. Users editing their app code (not the setup package) pay that tax on every preview.

On the CI side, both test jobs share a single `actions/cache` key and race on save, `examples/spm/.build` isn't cached at all, and `brew install swift-format` runs cold every format job.

### Success criteria

1. A warm `preview_start` on an unchanged setup package skips both `swift build` invocations and the `ar` archiving step. Measured: `SetupBuilder.build` returns in <100ms on cache hit (vs. baseline of several seconds).
2. Cache hit is safe: if any artifact referenced by the cached `compilerFlags` is missing on disk, the cache entry is treated as a miss and rebuilt.
3. Changing any `Package.swift` or `Sources/**/*.swift` file under the setup package invalidates the cache.
4. Switching platforms (macOS ↔ iOS) does **not** evict the other platform's entry.
5. CI `build-and-test` and `ios-tests` jobs no longer clobber each other's `.build` cache.
6. CI cold runs of the format job no longer wait on `brew install swift-format`.
7. `examples/spm/.build` is cached across CI runs.

## Tech Stack

- Swift 6.0, strict concurrency
- `SetupBuilder` lives in `Sources/PreviewsCore/SetupBuilder.swift` (platform-agnostic)
- Cache serialization: `JSONEncoder` / `JSONDecoder` on a `Codable` struct
- Hashing: `CryptoKit.SHA256` over sorted file paths + contents
- CI: GitHub Actions, `actions/cache@v4`, macOS-15 runners

## Commands

```bash
swift build
swift test --filter "SetupBuilderTests"
swift test --filter "PreviewsCoreTests"
swift-format lint --strict --recursive Sources/ Tests/ examples/
```

## Project Structure

New and changed files:

```
Sources/PreviewsCore/
├── SetupBuilder.swift                  # Modified: call into SetupCache
└── SetupCache.swift                    # New: hash, load, store, validate

Tests/PreviewsCoreTests/
└── SetupCacheTests.swift               # New: hit/miss/invalidation/corruption

.github/workflows/
└── ci.yml                              # Modified: split keys, add paths, cache brew

specs/
└── setup-cache.md                      # This file
```

Cache on disk:

```
<setupPackageDir>/.build/previewsmcp-setup-cache/
├── macos-<hash>.json
└── ios-<hash>.json
```

## Code Style

Match the existing `SetupBuilder.swift` style: a public `enum` namespace with `static` methods, `async throws` for IO, `Sendable` result structs, `LocalizedError` for errors.

```swift
enum SetupCache {

    struct Entry: Codable, Sendable {
        let moduleName: String
        let typeName: String
        let compilerFlags: [String]
        let sourceHash: String
        let swiftVersion: String
        let platform: String
    }

    /// Look up a cached build result. Returns nil on miss, corruption, or
    /// when any artifact referenced by compilerFlags no longer exists.
    static func load(
        packageDir: URL,
        platform: PreviewPlatform,
        sourceHash: String,
        swiftVersion: String
    ) -> SetupBuilder.Result? { ... }

    /// Persist a build result. Best-effort: failures to write are logged,
    /// not thrown, so a broken cache never breaks preview_start.
    static func store(
        _ result: SetupBuilder.Result,
        packageDir: URL,
        platform: PreviewPlatform,
        sourceHash: String,
        swiftVersion: String
    ) { ... }

    /// SHA256 of sorted (relativePath, fileContents) tuples for every
    /// Package.swift + Sources/**/*.swift under packageDir.
    static func hashSources(packageDir: URL) throws -> String { ... }
}
```

## Cache Design

### Key

SHA256 over, in order:

1. Sorted list of `(relativePath, SHA256(fileContents))` tuples for:
   - `<packageDir>/Package.swift`
   - Every `*.swift` file recursively under `<packageDir>/Sources/`
2. Swift toolchain version string (`swift --version` first line, trimmed)
3. Platform string (`"macos"` or `"ios"`)

Excluded from the hash: `Tests/`, `.build/`, `.swiftpm/`, resources, READMEs, tracked non-Swift files.

### Value

The full `SetupBuilder.Result` struct (moduleName, typeName, compilerFlags), serialized to JSON.

### Lookup flow

```
1. Hash sources → sourceHash
2. Read <packageDir>/.build/previewsmcp-setup-cache/<platform>-<sourceHash>.json
3. If file missing → MISS, fall through to full build
4. Decode JSON → Entry. If decode fails → MISS, delete corrupted file
5. Validate every path in compilerFlags that looks like a file/dir
   (-I <dir>, -L <dir>, -F <dir>, lib<name>.a, <Name>.framework) exists
   on disk. If any missing → MISS
6. Return SetupBuilder.Result
```

### Eviction

None. Entries are a few hundred bytes each; the hash space is bounded by actual source states. `swift package clean` wipes the parent `.build/`, which clears the cache naturally.

### Write path

Every successful `SetupBuilder.build` writes an entry at the end. Write failures are logged via `fputs` to stderr and swallowed — a broken cache must never break `preview_start`.

### SetupBuilder integration

```swift
public static func build(...) async throws -> Result {
    // ... existing package lookup ...
    let swiftVersion = try await resolveSwiftVersion()
    let sourceHash = try SetupCache.hashSources(packageDir: packageDir)

    if let hit = SetupCache.load(
        packageDir: packageDir,
        platform: platform,
        sourceHash: sourceHash,
        swiftVersion: swiftVersion
    ) {
        return hit
    }

    // ... existing full build path ...

    SetupCache.store(result, packageDir: packageDir,
                     platform: platform, sourceHash: sourceHash,
                     swiftVersion: swiftVersion)
    return result
}
```

## CI Improvements (second PR)

> **Note:** PR #88 already shipped Homebrew download caching (keyed on `Brewfile` hash) and added `examples/spm/.build` to both jobs' cache paths. The remaining CI work is the cache key split only.

### Split cache keys

Both `build-and-test` and `ios-tests` still share the key `spm-${{ runner.os }}-${{ hashFiles('Package.resolved') }}`. When both jobs run in parallel on the same commit, they race on cache save and can clobber each other. Split:

```yaml
# build-and-test job
- uses: actions/cache@v4
  with:
    path: |
      .build
      examples/spm/.build
    key: spm-${{ runner.os }}-build-${{ hashFiles('Package.resolved') }}
    restore-keys: |
      spm-${{ runner.os }}-build-
      spm-${{ runner.os }}-

# ios-tests job
- uses: actions/cache@v4
  with:
    path: |
      .build
      examples/spm/.build
    key: spm-${{ runner.os }}-ios-${{ hashFiles('Package.resolved') }}
    restore-keys: |
      spm-${{ runner.os }}-ios-
      spm-${{ runner.os }}-
```

The shared `spm-${{ runner.os }}-` fallback ensures cold jobs can still warm from the other job's cache.

### SetupBuilder cache in CI

No explicit action required — `<packageDir>/.build/previewsmcp-setup-cache/` lives under the already-cached `examples/spm/.build` path, so the setup cache rides along for free.

## Testing Strategy

Framework: `swift-testing` (matches existing suites).

New `Tests/PreviewsCoreTests/SetupCacheTests.swift`:

1. **`hashSources_stableAcrossRuns`** — same inputs → same hash
2. **`hashSources_sensitiveToPackageSwift`** — editing Package.swift changes hash
3. **`hashSources_sensitiveToSwiftSource`** — editing a .swift file changes hash
4. **`hashSources_ignoresTestsAndResources`** — adding files under Tests/, README.md, .build/ does not change hash
5. **`load_missReturnsNil`** — no cache file → nil
6. **`load_corruptJsonReturnsNilAndDeletes`** — malformed JSON → nil, file is removed
7. **`load_missingArtifactReturnsNil`** — valid JSON but referenced `.swiftmodule` gone → nil
8. **`store_thenLoad_roundTrip`** — store a Result, load it back byte-equal
9. **`store_ioFailureDoesNotThrow`** — read-only parent dir → store is silent no-op

Integration sanity check in `SetupBuilderTests`:

10. **`build_warmCacheSkipsSwiftBuild`** — build once, record wall time; build again, assert second call is an order of magnitude faster and returns the same flags

CI workflow changes are verified by inspection on a PR; GitHub Actions cache behavior is not unit-testable.

## Boundaries

- **Always:**
  - Validate cached artifact paths on disk before returning a hit
  - Swallow cache write errors — never break `preview_start`
  - Include platform and Swift toolchain version in the cache key
  - Run `swift test --filter SetupCacheTests` before committing either PR
- **Ask first:**
  - Changing the on-disk cache location (moving out from under `.build/`)
  - Adding new inputs to the hash (e.g., resources, Tests/)
  - Touching CoreSimulator caching (explicit non-goal — separate issue)
- **Never:**
  - Throw from cache read/write paths
  - Cache anything that isn't derivable from `(sources, platform, toolchain)`
  - Bypass the validation step on a hit

## Out of Scope

- **CoreSimulator device-set caching across CI runs.** This is the largest potential CI win (~10 min cold start on `SimServiceContext.deviceSetWithPath`) but is high-risk (daemon state, UDID stability, runtime assets) and deserves its own investigation. File as a separate issue, link from this spec.
- **Caching `xcodebuild` DerivedData** for the Xcode example. Out of scope; may revisit if users report slowness.
- **Hot-reload path caching.** Only the `SetupBuilder` startup cost is addressed here.

## Rollout

Two PRs, sequential:

1. **PR 1: SetupBuilder cache.** Adds `SetupCache.swift`, tests, and the integration call in `SetupBuilder.build`. Closes #81. No CI changes.
2. **PR 2: CI cache key split.** Splits the shared SPM cache key into per-job keys so `build-and-test` and `ios-tests` no longer clobber each other. (Homebrew and example caching already shipped in #88.)

## Success Criteria (testable)

- [ ] `SetupCacheTests` suite passes
- [ ] `SetupBuilderTests.build_warmCacheSkipsSwiftBuild` shows warm build ≥10x faster than cold
- [ ] `swift test` and `swift build` pass on CI
- [ ] On a PR that only touches docs, CI `build-and-test` restores a cache hit and `swift build` runs incrementally
- [ ] Two concurrent PRs to `build-and-test` and `ios-tests` no longer overwrite each other's `.build` cache entries

## Open Questions

None — all six scoping questions resolved during Phase 1.

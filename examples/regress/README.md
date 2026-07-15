# Regression Fixtures

These projects are synthetic reproductions for build and runtime shapes that are
easy to miss in a small app.
The fixtures are deliberately separate from the happy-path examples so a known
failure cannot make the normal integration suite unusable.

## Scenario Matrix

| ID | Directory / entry point | Boundary under test | Healthy result |
|---|---|---|---|
| D01 | `detection/mixed-marker-workspace/XcodeOnlyApp/Sources/MarkerPreview.swift` | Xcode project nested below a distant Bazel root | Select the nearer Xcode project |
| D02 | `detection/mixed-marker-workspace/NestedPackage/Sources/NestedPackage/NestedPackagePreview.swift` | Swift package nested below a Bazel root | Select the nested package |
| D03 | `detection/outer-spm-workspace/NestedXcode/Sources/OuterBoundaryPreview.swift` | Xcode project below an outer `Package.swift` | Select Xcode, not the outer package |
| D04 | `detection/outer-spm-workspace/NestedBazel/Sources/NestedBazelPreview.swift` | Bazel workspace below an outer `Package.swift` | Select the nested Bazel target |
| D05 | `detection/same-directory-markers/Sources/HybridMarker/HybridMarkerPreview.swift` | `Package.swift`, `MODULE.bazel`, and `BUILD.bazel` at one root | Apply a documented deterministic tie-breaker |
| D06 | `generated-project-state/missing-output/Sources/MissingOutputPreview.swift` | XcodeGen manifest with no generated project | Diagnose missing generated output and candidate markers |
| D07 | `generated-project-state/stale-output/Sources/NewPreview.swift` | Manifest is newer in meaning than its generated project | Diagnose stale output/source membership |
| D08 | `generated-project-state/multi-target/Sources/Beta/BetaPreview.swift` | One scheme builds multiple targets | Select the target that owns the source |
| D09 | `detection/path-variants/Space Package/Sources/PathFixture/Unicode–Preview.swift` | Spaces and Unicode in project/source paths | Preserve paths through detection, generated identifiers, subprocesses, and watchers |
| X01 | `xcode-workspace/App/Sources/WorkspacePreview.swift` | Multi-project workspace, referenced framework, custom configuration, and `.xcconfig` | Select the owning target, link the referenced project, and preserve the scheme configuration |
| X02 | `xcode-bridging/Sources/BridgingPreview.swift` | Objective-C bridging header on an Xcode app target | Forward the bridging header and compile/link the Objective-C sources |
| S01 | `spm-settings/Sources/SettingsFixture/SettingsPreview.swift` | Swift language mode, conditional flags, C module, generated source, resources, explicit membership | Reproduce SwiftPM's target compile command |
| S02 | `spm-settings/Sources/CompilerSettings/CompilerSettingsPreview.swift` | Swift language mode, upcoming features, unsafe flags, and conditional defines without other dependencies | Preserve the target's compile-affecting settings |
| S03 | `spm-settings/Sources/GeneratedPlugin/GeneratedPluginPreview.swift` | Build-tool plugin output without C or resource dependencies | Include the generated Swift source in Tier 2 compilation |
| S04 | `spm-settings/Sources/MembershipAndC/MembershipAndCPreview.swift` | Explicit source exclusion plus a Clang module | Omit excluded sources and preserve the C module map/search paths |
| S05 | `macro-target/Sources/MacroClient/MacroClientPreview.swift` | Custom macro declared and implemented in a SwiftPM macro target | Build the macro plugin for the host and load it during Tier 2 compilation |
| S06 | `macro-target/Sources/ToolchainMacroClient/ToolchainMacroPreview.swift` | Toolchain-provided macro (`@Observable`) with no package dependency | Resolve the macro through the default compiler plugin path |
| C01 | `literal-rewrite/Sources/LiteralRewrite/RangePreview.swift` | Integer literals adjacent to the half-open range operator | Preserve valid Swift syntax after thunk rewriting |
| C02 | `literal-rewrite/Sources/LiteralRewrite/LocalizedStringPreview.swift` | Literal-only overload requiring `String.LocalizationValue` | Preserve the typed literal or a compatible thunk |
| C03 | `config-cache/Nested/Sources/ConfigCache/ConfigCachePreview.swift` | A nearer config file appears while the daemon is alive | Invalidate the cached directory lookup and apply the nearer config |
| C04 | `config-cache/Nested/Sources/ConfigCache/ConfigCachePreview.swift` | The selected config is edited in place | Re-read its decoded content without restarting the daemon |
| C05 | `config-cache/Nested/Sources/ConfigCache/ConfigCachePreview.swift` | The selected nearer config is removed | Invalidate it and fall back to the parent config |
| B01 | `bazel-bzlmod/Sources/BzlmodPreview.swift` | Canonical external repository plus generated Swift output | Resolve paths from Bazel's execution state |
| B02 | `binary-frameworks/combined/Sources/CombinedBinaryFixture/BinaryFrameworkPreview.swift` | Static and dynamic simulator XCFrameworks in one target | Compile, link, embed, and load both correct slices |
| B03 | `binary-frameworks/static-only/Sources/StaticBinaryFixture/StaticBinaryPreview.swift` | Static XCFramework module and archive without a dynamic dependency | Discover the module and link its archive |
| B04 | `binary-frameworks/dynamic-only/Sources/DynamicBinaryFixture/DynamicBinaryPreview.swift` | Dynamic XCFramework loading plus an internal resource | Stage/load the framework and preserve its bundle resource |
| F01 | `binary-frameworks/bad-slice/Sources/BadSliceFixture/BadSlicePreview.swift` | Device-only XCFramework requested for a simulator | Return a classified incompatible-slice error and preserve daemon liveness |
| R01 | `runtime-frameworks/Sources/RuntimeFrameworks/FrameworkPreview.swift` | System-framework autolinks emitted by other source files | Render or return a classified session error without killing the daemon |
| R02 | `runtime-resources/Sources/RuntimeResources/ResourcePreview.swift` and `SpanishOnlyPreview.swift` | SwiftPM bundle resources, localization, and multi-preview switching | Read staged resources at preview runtime |
| R03 | `xcode-resources/Sources/ResourcePreview.swift` | Xcode-generated asset and Core Data sources plus runtime resources | Compile generated sources and use the built bundle |
| W01 | `hot-reload/Sources/HotReload/HotReloadPreview.swift` | Editing, adding, renaming, and removing dependency Swift sources | Reload the live session or report a classified compile error |
| W02 | `hot-reload/Sources/HotReload/HotReloadPreview.swift` | Resource-only and package-manifest changes | Rebuild/restage affected runtime inputs without a daemon restart |
| W03 | `hot-reload/Sources/HotReload/HotReloadPreview.swift` | Editor atomic-save patterns (rename-over and rename-away) | Keep watching through the file's changing identity and reload |
| W04 | `local-dependency/App/Sources/LocalDependencyApp/LocalDependencyPreview.swift` | Live edit inside a `.package(path:)` dependency package | Watch dependency sources and rebuild the dependency module before reload |
| T01 | `setup-faults/throwing/Sources/SetupFaultApp/SetupFaultPreview.swift` | Setup `setUp()` throws after a successful setup build | Render without setup, report a warning, and keep the daemon alive |
| T02 | `setup-faults/build-failure/Sources/SetupFaultApp/SetupFaultPreview.swift` | Setup package fails to compile while the app package is valid | Return a setup-specific build error and keep the daemon alive |
| T03 | `setup-faults/slow/Sources/SetupFaultApp/SetupFaultPreview.swift` | Long asynchronous setup execution | Emit elapsed-time progress and finish setup before the first render |
| V01 | `preview-forms/Sources/PreviewForms/LegacyProvider.swift` | Legacy `PreviewProvider` declaration | List and render its preview deterministically |
| V02 | `preview-forms/Sources/PreviewForms/ConditionalPreviews.swift` | `#if`-guarded preview declarations | List/select only declarations applicable to the active compile conditions |
| V03 | `preview-forms/Sources/PreviewForms/DuplicateNames.swift` | Two previews with the same display name | Preserve stable index-based selection |
| V04 | `preview-forms/Sources/PreviewForms/GenericContext.swift` | Preview expression using a constrained generic context | Compile and render the selected specialization |
| V05 | `preview-forms/Sources/PreviewForms/NoPreview.swift` | A SwiftUI view source with no preview declaration | Return a specific zero-preview diagnostic without stale state |
| L01 | `lifecycle-faults/Sources/SessionReplacement/SessionAPreview.swift` and `SessionBPreview.swift` | Same-device replacement | Deterministically replace or fail fast without a timeout |
| L02 | `lifecycle-faults/Sources/MissingSymbol/MissingSymbolPreview.swift` | Unresolved JIT symbol | Fail only the session; daemon remains responsive |
| L03 | `lifecycle-faults/Sources/SlowRender/SlowRenderPreview.swift` | Long render/setup phase | Emit elapsed-time heartbeats |
| L04 | `lifecycle-faults/Sources/AgentCrash/AgentCrashPreview.swift` | Preview-agent process crash | Report the failure and preserve daemon liveness |
| L05 | `lifecycle-faults/Sources/ConcurrentA/ConcurrentAPreview.swift` and `ConcurrentB/ConcurrentBPreview.swift` | Two sessions started simultaneously against one daemon | Both sessions start and render independently |
| I01 | `compound-controls/Sources/CompoundControls/CompoundControlsPreview.swift` | Row-sized accessibility frames vs. physical hit targets | Expose reliable semantic activation metadata |
| I02 | `compound-controls/Sources/CompoundControls/CompoundControlsPreview.swift` | Duplicate labels, stable identifiers, disabled/no-match/no-change outcomes | Target one semantic element and acknowledge the observed outcome |
| I03 | `compound-controls/Sources/CompoundControls/CompoundControlsPreview.swift` preview 2 | Scaled/rotated controls and physical coordinates | Return a transformed activation point that remains actionable |
| P01 | `large-tier2/Sources/LargeTier2/LargeTier2Preview.swift` | Hundreds of Tier 2 source files | Emit compile heartbeats and eventually render |
| M01 | `.bazelignore`, `.mcp.json`, and worktree-local checkout roots | Bazel traversal and MCP binary selection when worktrees live below the repo | Ignore nested worktrees and launch the binary from the active checkout |
| M02 | daemon version handshake (no source fixture) | Newer CLI connecting to an older running daemon | Detect the mismatch and restart the daemon from the current binary |

## Verification

Every matrix row has been exercised against the Bazel-built CLI on macOS, and
the simulator-dependent rows have been exercised on iOS. The dated outcomes,
controls, fixture corrections, and repeatability notes are in
[`VERIFICATION.md`](VERIFICATION.md).

A reproduced current failure is not a passing test. The healthy-result column
remains the acceptance contract, while D02 and D05 currently act as guards for
working behavior and an explicit precedence decision.

## How to Use the Matrix

Build the repository CLI through Bazel, then run one scenario at a time. For
example:

```bash
bazel run //previewsmcp/cli:previewsmcp -- run \
  examples/regress/compound-controls/Sources/CompoundControls/CompoundControlsPreview.swift \
  --platform ios --detach
```

Some fixtures intentionally need setup:

- Run `xcodegen generate` in an Xcode fixture that does not commit generated
  output. D01, D03, D07, D08, and X01 commit their generated projects because
  the projects' presence or contents are part of the reproduction.
- Run `binary-frameworks/generate-artifacts.sh` before B02, B03, B04, or F01.
- The first S05/S06 build fetches and compiles the pinned `swift-syntax`
  dependency; `macro-target/Package.resolved` is the pin.
- Run `large-tier2/generate-sources.sh` before P01.
- D06 intentionally has no `.xcodeproj`; generating it destroys that scenario
  until the generated directory is removed again.
- L02 and L04 are expected to fail. Their assertion is that the same daemon can
  answer a subsequent `list` or start request.
- Each setup-fault subdirectory is a separate package/config root. Run its
  source in place rather than pointing one case at a sibling's config.

Use `--build-system` only when a scenario explicitly tests resolved compiler or
runtime state. Detection scenarios must first run without an override.

## Adjacent Gaps Captured Here

The original failure families imply several nearby boundaries, so the matrix
also covers:

- explicit target source membership and excluded files;
- build-tool generated Swift sources and watcher inputs;
- C headers/module maps alongside Swift target settings;
- static versus dynamic XCFramework runtime handling;
- localized/resource-bearing bundles and generated asset/Core Data sources;
- agent crashes and unresolved symbols as separate failure classes;
- disabled, hidden-label, nested, scroll-dependent, and duplicate-label
  controls in the accessibility tree;
- same-directory marker ambiguity as a product decision, not accidental order;
- slow setup/render work in addition to slow `swiftc` work.
- literal rewriting at operator boundaries where token spacing is significant.
- config discovery invalidation when a nearer project config is added or removed.
- config invalidation when selected contents change without a path change.
- setup build, runtime, and asynchronous-completion failures as distinct phases.
- preview syntax/selection boundaries and non-ASCII generated identifiers.
- source-only versus resource-only hot reloads.
- multi-project workspace ownership and custom build configurations.
- macro plugin executables, both package-defined and toolchain-provided.
- Objective-C visible only through a bridging header, not a module.
- editor save styles that replace the file instead of rewriting it in place.
- watcher coverage across local package-dependency boundaries.
- concurrent session starts against one daemon.
- CLI/daemon version skew as a lifecycle boundary.

Future additions should remain small, local, network-free apart from fetching
the same pinned public build rules used by the existing examples (plus
`macro-target/`'s pinned `swift-syntax`, which macro implementations cannot
avoid), and should add one row to the scenario matrix.

The local `.previewsmcp.json` intentionally stops config discovery before it
reaches `examples/.previewsmcp.json`; regression previews must not inherit the
happy-path ToDo setup plugin.

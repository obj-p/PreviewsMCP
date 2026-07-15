# Regression Fixture Verification

Last full manual pass: 2026-07-14. Detection rows (D01–D09, X02's detection
half) re-verified 2026-07-15 after the ownership-walk resolver landed
(`docs/build-system-resolver.md`, stage 1). SwiftPM compile rows (S01–S06,
D09, W01's edit variant) re-verified 2026-07-15 after compile-command
capture landed (stage 2). Xcode rows (X01, X02, D08, R03, D01/D07 guards)
re-verified 2026-07-15 after build-log capture landed (stage 3). Bazel and
binary-framework rows (B01–B04, D04/D05 guards) re-verified 2026-07-15
after aquery capture landed (stage 4).

Environment: Xcode 26.2, an iOS 26.3 `previewsmcp-test` iPhone simulator,
and the Bazel-built CLI from this checkout. Commands used an isolated daemon
socket directory so the verification did not share sessions with the normal
development daemon.

`Reproduced` means the current product exhibited the boundary's failure or
missed acceptance contract and a native or forced-build-system control showed
that the fixture itself was usable. `Guard passes` means the current product
already handles the case. Some gaps are undesirable success or stale state,
not a nonzero command exit.

| ID | Result | Observed current behavior and control |
|---|---|---|
| D01 | Guard passes | 2026-07-15 (ownership walk): auto-detection confirmed membership in the nearer Xcode project and rendered `Nearest marker: Xcode`. Previously the distant SwiftPM root claimed the file and failed. |
| D02 | Guard passes | Auto-detection selected the nested SwiftPM package and started the preview. Re-verified 2026-07-15 under the ownership walk. |
| D03 | Guard passes | 2026-07-15 (ownership walk): auto-detection selected the nested Xcode project and rendered `Outer Package.swift must not win`. Previously the outer SwiftPM package claimed it. |
| D04 | Guard passes | 2026-07-15 (ownership walk): auto-detection selected the nested Bazel workspace and rendered `Outer Package.swift must not win`. Previously the outer SwiftPM package claimed it. |
| D05 | Guard passes | Auto-detection selected SwiftPM and rendered. The same-level precedence (SwiftPM, then Bazel, then Xcode) is now the documented tie-break in the ownership walk, re-verified 2026-07-15. |
| D06 | Guard passes | 2026-07-15 (ownership walk): the start error names every declined candidate (the fixture's fallback package and workspace, the repo root) and the `project.yml` manifest with `run xcodegen generate`. Previously a generic SwiftPM ownership failure. |
| D07 | Guard passes | 2026-07-15 (ownership walk): the start error reports that no target in `StaleOutput.xcodeproj` compiles `NewPreview.swift` and that the project may be stale relative to its XcodeGen manifest. Previously the outer SwiftPM root claimed the file and forced Xcode silently rendered a file outside the project. |
| D08 | Guard passes | 2026-07-15 (ownership walk): membership confirmed target `Beta`; the `Combined` scheme's build settings are parsed for that target and the preview rendered `Beta owns this preview`. Previously it compiled as module `Alpha` and failed. |
| D09 | Guard passes | 2026-07-15 (compile capture): derived module names are sanitized to valid identifiers; rendered `path fixture: café` through the spaced/Unicode fixture path. |
| X01 | Guard passes | 2026-07-15 (Xcode compile capture): the iOS snapshot rendered `cross-project dependency` and `custom workspace configuration` — the scheme's own configuration drives the build (no forced -configuration), so `PREVIEW_WORKSPACE` from the selected `.xcconfig` arrives via the captured command, and products-dir dependency frameworks are dlopen-staged for the JIT. |
| S01 | Guard passes | 2026-07-15 (compile capture): rendered `Compiler settings preserved`, the processed resource, `build-tool generated`, `C module value: 42`, and `Conditional Swift setting present`. The captured command carries the C module map and defines; the captured inputs honor the exclusion and include the plugin-generated source. |
| S02 | Guard passes | 2026-07-15 (compile capture): rendered `ExistentialAny enabled` and `Conditional Swift setting present` — the conditional define, upcoming feature, and unsafe flags forward through the normalized captured command. |
| S03 | Guard passes | 2026-07-15 (compile capture): the plugin-generated `GeneratedFixtureStamp` is a captured compile input; rendered `build-tool generated`. |
| S04 | Guard passes | 2026-07-15 (compile capture): the exclusion is honored by the captured inputs and the Clang module resolves; rendered `C module value: 42`. |
| S05 | Guard passes | 2026-07-15 (compile capture): rendered `custom macro expansion active`. The captured `-Xfrontend -load-plugin-executable` points at the host-built plugin SwiftPM already produced (#413). |
| S06 | Guard passes | The `@Observable` toolchain macro compiled through the default plugin path and the preview rendered `toolchain macro active` on macOS. Re-verified 2026-07-15 under compile capture. |
| X02 | Guard passes | 2026-07-15 (Xcode compile capture): rendered `bridged objc active`. The captured command carries `-import-objc-header` and the target's C/ObjC objects are archived for the JIT link, closing #414. |
| C01 | Reproduced | Native SwiftPM build passed. Literal thunking changed `0 ..< 12` into a parser-invalid operator boundary (`'..<' is not a postfix unary operator`). |
| C02 | Reproduced | Native SwiftPM build passed. String thunking produced `String` where `String.LocalizationValue` was required. |
| C03 | Guard passes | 2026-07-15 (state-invalidation stage 1): `ConfigCache` deleted; discovery walks fresh per lookup. A nearer dark config appearing was applied by the same daemon's next start (snapshot rendered `dark` after the parent-`light` baseline). |
| C04 | Guard passes | 2026-07-15 (state-invalidation stage 1): the nearer config edited in place from `dark` to `light` was re-read by the same daemon's next start (snapshot rendered `light`). |
| C05 | Guard passes | 2026-07-15 (state-invalidation stage 1): removing the nearer dark config fell back to the parent light config on the same daemon's next start (snapshot rendered `light`). A contract test (`configQualityRereadsFilesystem`) pins all three transitions on the quality-lookup path. |
| B01 | Guard passes | 2026-07-15 (Bazel aquery capture): rendered `Canonical Bzlmod repository` and `Bazel generated source`. The SwiftCompile action's arguments carry the generated source at its execroot path and the canonical external repo's module search path; external dependency archives are force-built for the JIT link. |
| B02 | Guard passes | 2026-07-15 (compile capture): rendered both `Static simulator XCFramework` and `Dynamic simulator XCFramework` on iOS — the captured flags resolve the StaticBadge module and the copied static archive in binPath links alongside the dynamic framework. |
| B03 | Guard passes | 2026-07-15 (compile capture): rendered `Static simulator XCFramework` on iOS; the static XCFramework's module resolves from the captured flags and its copied `libStaticBadge.a` links from binPath. |
| B04 | Reproduced | The dynamic-only package passed natively and PreviewsMCP loaded it on iOS: the snapshot rendered `Dynamic simulator XCFramework`. The same snapshot reported `framework resource missing`, so the framework's internal JSON was not staged with the loaded binary. |
| F01 | Reproduced | The generator and XCFramework metadata provide only an iPhoneOS device slice. Native simulator and PreviewsMCP builds both failed `no such module 'BadSlice'`; PreviewsMCP did not classify the incompatible slice, while the daemon remained responsive. |
| R01 | Reproduced | macOS and iOS reached JIT materialization and failed on the target-wide framework/autolink closure. The CLI error was an unclassified symbol dump; the daemon remained responsive. |
| R02 | Reproduced | English JSON, text, and localization resources rendered on macOS and iOS. Both selecting preview index 1 and an explicit single-preview Spanish localization control produced a blank or partial framebuffer on iOS. Native SwiftPM build passed and both locale directories were present in the staged bundle. |
| R03 | Reproduced | macOS and iOS rendered the generated color symbol, while the localized key remained `resource.title` and plist/Core Data lookup reported missing. The cold iOS Xcode build also spent about 49 seconds in one progress step. Re-verified 2026-07-15 under Xcode compile capture: the generated-sources half renders identically; the remaining gap is runtime-resource staging (out of the resolver's scope). |
| W01 | Partial guard | Editing a dependency Swift file live changed `source version one` to `source version two` in a stable follow-up snapshot without restarting the session. The add/rename/remove variants are present in the fixture instructions but were not all exercised in this pass. Edit variant re-verified 2026-07-15 with the watcher fed by captured compile inputs; the fixture's Swift 6 language mode also forced two generated-source concurrency fixes (DesignTimeStore, window-state observer). |
| W02 | Reproduced | Changing only `Resources/reload-value.txt` produced a reload transition, but stable follow-up snapshots still showed `resource version one`; the rebuilt/staged resource was stale. |
| W03 | Guard passes | Both editor save styles reloaded on macOS: write-temp-then-rename-over and rename-away-then-recreate each updated the render to the new source value in a stable follow-up snapshot. |
| W04 | Reproduced | The App preview rendered `dependency version one`. Editing `SharedLocal/Sources/SharedLocal/SharedValue.swift` in the live session produced no watcher or rebuild activity in the daemon log, and follow-up snapshots at 10 and 30 seconds were byte-identical stale renders. The dependency package's sources are not watched. |
| T01 | Reproduced | Both app and setup packages built. `setUp()` threw and the app rendered without setup, but the CLI returned success without the documented warning; the snapshot contained only the app content. |
| T02 | Guard passes | The app package built, the setup package failed at its intentional syntax error, and PreviewsMCP returned `Setup package 'BrokenPreviewSetup' build failed` with the compiler diagnostic. Daemon status remained healthy. |
| T03 | Reproduced | The setup implementation sleeps for eight seconds, but `run` returned a started session in about 2.3 seconds after the compile line and emitted no setup-execution heartbeat. The first-render contract did not await asynchronous setup completion. |
| V01 | Guard passes | `list` found the legacy `PreviewProvider` expression and PreviewsMCP rendered it on macOS. |
| V02 | Reproduced | On macOS, `list` exposed both the debug preview and the `#if os(iOS)` preview. Switching to the iOS-only index reported success and compiled its extracted expression outside the original platform guard. |
| V03 | Guard passes | Both duplicate names were listed with stable indices; starting index 1 selected the second declaration. |
| V04 | Guard passes | The constrained generic specialization compiled and rendered on macOS. |
| V05 | Guard passes | `list` returned no rows, and `run` returned the specific diagnostic `Preview index 0 not found. File has 0 preview(s).` |
| L01 | Reproduced | Session B started on the same device after Session A, but A remained registered. `variants` for A then failed with `iOS preview session has not been started`; after explicitly stopping stale A, the identical variants command succeeded. |
| L02 | Reproduced | The daemon log named the injected unresolved symbol. The CLI collapsed it to a `_renderPreviewToFile` materialization failure, while daemon status remained healthy. |
| L03 | Reproduced | The eight-second render completed, but timestamps showed an eight-second silent interval with no elapsed-time heartbeat. |
| L04 | Reproduced | Tapping the crash button terminated the original agent PID and logged transport disconnects. `touch` still reported success and a later `elements` call returned the stale tree; the daemon itself remained alive. |
| L05 | Guard passes | Two simultaneous detached starts from the same package returned distinct session UUIDs, and each session's snapshot showed its own content (macOS; the same-device iOS variant remains covered by L01). |
| I01 | Reproduced | `elements` reported the trailing toggle as a 370-point-wide row. A center tap left value `0`; an edge tap changed it to `1`. Toggle identifiers were absent from the returned tree. |
| I02 | Reproduced | The tree contained duplicate labels and a disabled trait, but most toggle identifiers were absent and the CLI offered only coordinate injection. A dispatched tap acknowledged only `Tap sent`, not matched element, enabled state, or observed value change. |
| I03 | Reproduced | The scaled/rotated preview started and returned transformed-looking axis-aligned frames but no activation points. Tapping the reported center of the standard toggle returned success while its value remained `0`. |
| P01 | Reproduced | A cold 2,000-file run rendered successfully after an 11.8-second silent build step with no heartbeat. A warm 800-file run took about two seconds and was not a reproduction. |
| M01 | Guard passes | Root `.bazelignore` contains both `.claude/worktrees` and `.worktrees`; root Bazel query/build do not traverse the regression matrix or nested worktrees. Worktree-local MCP binary selection remains a launch/integration assertion rather than a source fixture. |
| M02 | Guard passes | A daemon advertising `0.0.1-stale` (via the `_PREVIEWSMCP_TEST_DAEMON_VERSION` hook) was detected at connect: the CLI printed `daemon was 0.0.1-stale, CLI is ... — restarting`, killed it, respawned from its own binary under the restart lock, and completed the command. Like M01, this is a launch assertion with no source fixture. |

## Fixture Corrections Made During Verification

- Split lifecycle fault families into separate SwiftPM targets. The injected
  L02 unresolved symbol previously contaminated L01, L03, and L04.
- Added a single-preview Spanish resource control and made locale selection
  explicit in the Foundation localization call. The prior environment-only
  variant did not actually select Foundation's localization locale.
- Split combined/static/dynamic/bad-slice XCFramework cases into separate
  SwiftPM package roots after a package-wide build let the bad slice contaminate
  supposedly isolated targets.
- Made the hot-reload target's source/resource path explicit after SwiftPM
  inferred resources relative to the wrong directory name.
- Added the custom `Preview Debug` configuration to both workspace projects;
  without it, the native control could not build the referenced framework.
- Made S01/S02 fail closed (2026-07-15, guard automation): the `#else`
  branches that rendered "setting missing" text became `#error`, and S01's
  missing-resource fallback became a `fatalError`, so a regression is a
  loud compile/render failure instead of a silently-wrong render that an
  exit-code guard would miss. The healthy render is unchanged.

## Repeatability Notes

- Run detection cases without overrides first; forced build systems are
  controls only.
- B02, B03, B04, and F01 require
  `binary-frameworks/generate-artifacts.sh`.
- P01 requires `large-tier2/generate-sources.sh`; set `FILE_COUNT=2000` and
  clean that fixture's SwiftPM products for the cold timing check.
- Use a dedicated simulator and isolated `PREVIEWSMCP_SOCKET_DIR` for the iOS
  rows. Stop sessions between unrelated cases, except where stale or
  same-device state is the assertion.
- Verify rendered resource and interaction assertions from snapshots and
  `elements` values, not command exit codes alone.

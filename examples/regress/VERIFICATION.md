# Regression Fixture Verification

Last full manual pass: 2026-07-14. Detection rows (D01–D09, X02's detection
half) re-verified 2026-07-15 after the ownership-walk resolver landed
(`docs/build-system-resolver.md`, stage 1). SwiftPM compile rows (S01–S06,
D09, W01's edit variant) re-verified 2026-07-15 after compile-command
capture landed (stage 2). Xcode rows (X01, X02, D08, R03, D01/D07 guards)
re-verified 2026-07-15 after build-log capture landed (stage 3). Bazel and
binary-framework rows (B01–B04, D04/D05 guards) re-verified 2026-07-15
after aquery capture landed (stage 4). B04, R02, and R03 re-verified
2026-07-21 ahead of the resource-staging family work.

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
| C05 | Guard passes | 2026-07-15 (state-invalidation stage 1): removing the nearer dark config fell back to the parent light config on the same daemon's next start (snapshot rendered `light`). Automated: `configQualityRereadsFilesystem` pins all three transitions on the quality-lookup path, and `RegressGuardTests.configRowsFreshPerStart` drives the same-daemon start sequence end to end. |
| B01 | Guard passes | 2026-07-15 (Bazel aquery capture): rendered `Canonical Bzlmod repository` and `Bazel generated source`. The SwiftCompile action's arguments carry the generated source at its execroot path and the canonical external repo's module search path; external dependency archives are force-built for the JIT link. |
| B02 | Guard passes | 2026-07-15 (compile capture): rendered both `Static simulator XCFramework` and `Dynamic simulator XCFramework` on iOS — the captured flags resolve the StaticBadge module and the copied static archive in binPath links alongside the dynamic framework. |
| B03 | Guard passes | 2026-07-15 (compile capture): rendered `Static simulator XCFramework` on iOS; the static XCFramework's module resolves from the captured flags and its copied `libStaticBadge.a` links from binPath. |
| B04 | Guard passes | 2026-07-21: with the fixture's lookup corrected (see Fixture Corrections), the iOS snapshot renders both the framework message and the internal JSON payload — the EPC-dlopened framework resolves via `Bundle(for:)` and serves its root-level resource, so nothing was ever missing from staging. The recorded `framework resource missing` was the fixture's own mechanism twice over: `Bundle.allFrameworks` only lists frameworks containing at least one ObjC class (DynamicBadge was pure C, so it could never be enumerated — proven natively with a dlopen control), and the JSON sat in a `Resources/` subdirectory of a flat iOS framework. B02's combined render re-verified after the artifact change. |
| F01 | Guard passes | 2026-07-20 (phase/error stage 4): the iOS start returns the classified error `XCFramework 'BadSlice' has no iOS simulator slice (available: ios-arm64).` with a rebuild remediation — the enricher reads the declared binary target's `Info.plist` when a `no such module` names it, and any miss degrades to the plain build failure. Daemon stays responsive. |
| R01 | Guard passes | 2026-07-20 (phase/error stage 4): the start returns a classified session error — `Rendering the preview failed: JIT link could not resolve 3 symbol(s): _SCNVector3Zero, _OBJC_CLASS_$_SCNScene, _OBJC_CLASS_$_LPLinkMetadata` — naming the autolink closure's actual symbols, with the bounded list and an autolink remediation. The daemon stays responsive; rendering the closure remains named future work (`LC_LINKER_OPTION` scan). |
| R02 | Guard passes | 2026-07-21: the original blank/partial framebuffer no longer reproduces, and with the fixture's Spanish assertion corrected (see Fixture Corrections) every surface renders `Recursos cargados` — the macOS control, the iOS single-preview control, and iOS index 1 after a live switch — alongside the JSON and text rows. The re-verification first found all surfaces rendering the English title, but a native harness against the healthy built bundle proved that was the fixture's own mechanism: `String(localized:bundle:locale:)` does not select the `.lproj` (its `locale:` parameter affects interpolation formatting only), so the 2026-07-15 fixture variant could never display Spanish even against correct staging. Original 2026-07-14 observation, for history: index 1 and the Spanish control produced a blank or partial framebuffer on iOS while the native build passed with both locale directories staged. |
| R03 | Reproduced | macOS and iOS rendered the generated color symbol, while the localized key remained `resource.title` and plist/Core Data lookup reported missing. The cold iOS Xcode build also spent about 49 seconds in one progress step. Re-verified 2026-07-15 under Xcode compile capture: the generated-sources half renders identically; the remaining gap is runtime-resource staging (out of the resolver's scope). Re-verified 2026-07-21: macOS unchanged (the generated color renders; `resource.title`, plist, and Core Data model still miss). iOS regressed to a deterministic agent crash — `JIT link failed: disconnecting`, the agent SIGILLs executing an x86_64 prologue (`55 48 89 e5`) in JIT memory. The generic `iOS Simulator` destination builds every arch (the products framework is fat x86_64+arm64), the build-log capture takes an x86_64 swift-frontend invocation, and `stripForeignTargetTriple`'s iOS check (`triple.contains("simulator")`) accepts the foreign-arch simulator triple. |
| W01 | Partial guard | Editing a dependency Swift file live changed `source version one` to `source version two` in a stable follow-up snapshot without restarting the session. The add/rename/remove variants are present in the fixture instructions but were not all exercised in this pass. Edit variant re-verified 2026-07-15 with the watcher fed by captured compile inputs; the fixture's Swift 6 language mode also forced two generated-source concurrency fixes (DesignTimeStore, window-state observer). |
| W02 | Guard passes | 2026-07-16 (state-invalidation stage 4): a resource-only edit to `Resources/payload.json` fired the runtime-input tier — the daemon logged `Evidence change: re-running the native build` — and a stable follow-up snapshot rendered the new value; the revert refreshed back. Regression note on the original observation: on stage-3 code, neither an in-place nor an atomic-rename resource-only edit produces any watcher activity (the resource path cannot pass the exact-path filter), and a snapshot logs only clean MCP lines — the originally recorded "reload transition" therefore came from the operator's editor re-saving an open watched source file in the same burst, not from the resource edit. |
| W03 | Guard passes | Both editor save styles reloaded on macOS: write-temp-then-rename-over and rename-away-then-recreate each updated the render to the new source value in a stable follow-up snapshot. |
| W04 | Guard passes | 2026-07-16 (state-invalidation stage 4): editing `SharedLocal/Sources/SharedLocal/SharedValue.swift` in the live session fired the source-directory tier, the daemon rebuilt natively and reloaded (`Refreshed (native rebuild + reload)`), and the snapshot rendered `dependency version two`; the revert refreshed back through the reinstalled watcher. Two co-rooted sessions driven through the same shared dependency edit both refreshed with zero failures — SwiftPM's build-directory lock serialized the concurrent rebuilds. A mid-session `xcodegen generate` on the stale-output fixture (D07 residue) re-resolved twice (manifest burst, then regenerated-pbxproj burst) with the render intact and no refresh loop. |
| T01 | Guard passes | 2026-07-20 (phase/error stage 3): the start succeeds and carries the documented warning — `Preview setup 'ThrowingSetup' failed: intentional setup runtime failure. The preview rendered without setup.` — as a notice on the start response (CLI stderr + `structuredContent.notices` + `setupWarning`); the snapshot confirms `wrap` was skipped (no setup overlay); the daemon stays alive. Verified on macOS and iOS (the setup-error sidecar round-trips from the simulator agent). Regression note on the original observation: `setUp()` never actually threw — setup was silently dropped for single-source targets (`hasSetup` was gated on the Tier 2 split context, and captured inputs exclude the preview file), so nothing ran at all. Stage 3 decoupled the gate; the throw-swallowing `try?` in the generated entry was the second latent defect behind the row. |
| T02 | Guard passes | The app package built, the setup package failed at its intentional syntax error, and PreviewsMCP returned `Setup package 'BrokenPreviewSetup' build failed` with the compiler diagnostic. Daemon status remained healthy. |
| T03 | Guard passes | 2026-07-20 (phase/error stage 3): setup runs as its own phase with an elapsed-time heartbeat — `[4/5] Running preview setup...` then `(5s)` — blocks the start for the full eight seconds, and completes before the first render (`[5/5] Rendering preview...`; the snapshot shows the wrapper's "slow setup completed"). Regression note on the original observation: the ~2.3s "early return" was not an ordering defect — setup was silently dropped for single-source targets (the same `hasSetup` split-gate T01's note describes), so nothing awaited because nothing ran. When wired, the first-render contract always held. |
| V01 | Guard passes | `list` found the legacy `PreviewProvider` expression and PreviewsMCP rendered it on macOS. |
| V02 | Reproduced | On macOS, `list` exposed both the debug preview and the `#if os(iOS)` preview. Switching to the iOS-only index reported success and compiled its extracted expression outside the original platform guard. |
| V03 | Guard passes | Both duplicate names were listed with stable indices; starting index 1 selected the second declaration. |
| V04 | Guard passes | The constrained generic specialization compiled and rendered on macOS. |
| V05 | Guard passes | `list` returned no rows, and `run` returned the specific diagnostic `Preview index 0 not found. File has 0 preview(s).` |
| L01 | Guard passes | 2026-07-15 (state-invalidation stage 2): starting B on A's device performed an ordered replacement — the daemon logged `claimed device (replaced=<A>)`, A was deregistered (a `variants` against it failed in 0.05s with no timeout), and B rendered. `DeviceClaimsTests` pins the contended paths (mid-launch claims waited out, replacement ordered, lost claims reported). |
| L02 | Guard passes | 2026-07-20 (phase/error stage 4): the ORC session error reporter (installed on the remote-session LLJIT, attempt-scoped) carries `Symbols not found: [ _previewsmcp_fixture_symbol_that_does_not_exist ]` WITH the failure instead of beside it in the log; the CLI shows the classified `JIT link could not resolve 1 symbol(s): …` naming the injected symbol. Daemon status stays healthy. |
| L03 | Guard passes | 2026-07-19 (phase/error stage 2): the eight-second render ticks an elapsed-time heartbeat — `[4/4] Rendering preview... (5s)` on the CLI's stderr mid-render — and completes. The previously silent interval is now heartbeated by the phase clock. |
| L04 | Guard passes | 2026-07-15 (state-invalidation stage 2): the killing tap returned a classified `Connection to agent app lost` error (touch is now an acknowledged round-trip), the daemon logged `agent died out of band (crash #1); respawning`, the next `elements` succeeded and carried the crash notice as a trailing content item, the follow-up `touch` was clean (notice cleared on delivery), and the daemon stayed alive. |
| L05 | Guard passes | Two simultaneous detached starts from the same package returned distinct session UUIDs, and each session's snapshot showed its own content (macOS; the same-device iOS variant remains covered by L01). |
| I01 | Reproduced | `elements` reported the trailing toggle as a 370-point-wide row. A center tap left value `0`; an edge tap changed it to `1`. Toggle identifiers were absent from the returned tree. |
| I02 | Reproduced | The tree contained duplicate labels and a disabled trait, but most toggle identifiers were absent and the CLI offered only coordinate injection. A dispatched tap acknowledged only `Tap sent`, not matched element, enabled state, or observed value change. |
| I03 | Reproduced | The scaled/rotated preview started and returned transformed-looking axis-aligned frames but no activation points. Tapping the reported center of the standard toggle returned success while its value remained `0`. |
| P01 | Guard passes | 2026-07-19 (phase/error stage 2): a cold 2,000-file run emitted compile heartbeats — `[2/4] Building (SPMBuildSystem)... (5s)` and `(10s)` during the ~11-second build step — and rendered. Sub-5-second phases stay tick-free. |
| M01 | Guard passes | Root `.bazelignore` contains both `.claude/worktrees` and `.worktrees`; root Bazel query/build do not traverse the regression matrix or nested worktrees. Worktree-local MCP binary selection remains a launch/integration assertion rather than a source fixture. |
| M02 | Guard passes | A daemon advertising `0.0.1-stale` (via the `_PREVIEWSMCP_TEST_DAEMON_VERSION` hook) was detected at connect: the CLI printed `daemon was 0.0.1-stale, CLI is ... — restarting`, killed it, respawned from its own binary under the restart lock, and completed the command. Like M01, this is a launch assertion with no source fixture. |

## Fixture Corrections Made During Verification

- Split lifecycle fault families into separate SwiftPM targets. The injected
  L02 unresolved symbol previously contaminated L01, L03, and L04.
- Added a single-preview Spanish resource control and made locale selection
  explicit in the Foundation localization call. The prior environment-only
  variant did not actually select Foundation's localization locale.
- Corrected B04's resource assertion (2026-07-21): `Bundle.allFrameworks`
  never lists a framework without ObjC classes, and a flat iOS framework's
  resources belong at its root, not under `Resources/`. DynamicBadge now
  carries an ObjC marker class, the JSON moved to the framework root, and
  the preview resolves through `Bundle(for:)` with distinct failure states
  (`framework class not registered` / `framework bundle unresolved` /
  `framework resource missing`).
- Replaced the Spanish assertion mechanism again (2026-07-21):
  `String(localized:bundle:locale:)` does not select the `.lproj` either (the
  `locale:` parameter affects interpolation formatting only, proven natively
  against the built bundle), so the title now resolves through the locale's
  `.lproj` sub-bundle explicitly and shows `<locale>.lproj missing` or
  `resource.title unresolved` when staging drops the directory or the key.
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

# JIT Bundle Resolution: user code finds the framework it was compiled from

Status: DRAFT for review — 2026-07-21

The JIT recompiles a target's sources into the agent process instead of
loading the target's built binary, so a class declared in target code lives
in the agent image, not in the framework Xcode built. `Bundle(for:)` on such
a class therefore resolves to the agent's bundle — which holds none of the
target's resources — while the real framework wrapper sits fully populated
on disk (compiled string catalogs, plists, Core Data models, asset
catalogs). One narrow carve-out exists today: generated
`Generated*Symbols.swift` files are text-rewritten to point at the wrapper
(`applyResourceBundleRewrites`, #151), which is why a generated asset color
renders while a hand-written `Bundle(for:)` lookup two lines away misses.
The fix is one rule: **a bundle lookup made by JIT-compiled code resolves to
the on-disk wrapper of the target it was compiled from, without the user's
source changing.**

## Matrix rows this retires

| Row | Remaining gap | Shared root cause |
|---|---|---|
| R03 | `resource.title` raw, plist miss, momd miss on macOS and iOS while the generated color renders | `Bundle(for: <class in the preview file>)` resolves to the agent image because the class is compiled into the JIT module (`Compiler.swift:146-176,199-272`); the rewrite that saves the color is filtered to `Generated*Symbols.swift` with an exact-needle match (`XcodeBuildSystem.swift:666-682`), so user sources never get it |

## What re-verification already closed (2026-07-21, this branch)

The resource-staging cluster began as three Reproduced rows. Two fell to
fixture-mechanism defects, not product gaps — each proven with a native
control before touching the product, and each fixed in the fixture with
distinguishable failure states:

- **R02** (SwiftPM localization): `String(localized:bundle:locale:)` never
  selects an `.lproj` — the `locale:` parameter only affects interpolation
  formatting. The staged bundle was healthy all along; the corrected
  fixture resolves through the locale's `.lproj` sub-bundle and every
  surface renders Spanish (commit `d82707a`).
- **B04** (XCFramework internal resource): `Bundle.allFrameworks` only
  lists frameworks containing ObjC classes, and DynamicBadge was pure C —
  the fixture could not observe the framework under any product behavior;
  its JSON also sat under `Resources/` in a flat iOS framework. With an
  ObjC marker class and a root-level resource, the EPC-dlopened framework
  resolves via `Bundle(for:)` and serves the payload (commit `c93257a`).
  This also establishes the load path is sound: a **real** dynamic
  framework loaded from the build directory keeps its wrapper identity in
  the agent.
- **R03's iOS crash** was a separate defect — the fat-build x86_64 capture
  — fixed on main (#438).

The lesson the family keeps: verify a row's assertion mechanism natively
(outside the daemon) before reading it as a product gap.

## Today's shape (evidence)

- **Target code is recompiled, never loaded.** The preview file compiles as
  the overlay and the target's remaining sources as the stable module, both
  to fresh objects the JIT materializes into the agent
  (`Compiler.swift:146-176,199-272`); "the target's own framework is the
  Tier 2 recompile itself, never loaded"
  (`XcodeBuildSystem.swift:255-256`). A class compiled this way has no dyld
  image inside the framework wrapper, so Foundation resolves
  `Bundle(for:)` to the agent bundle.
- **The resources exist.** Both platforms' built products contain
  `Assets.car`, `en.lproj/Localizable.strings` and
  `es.lproj/Localizable.strings` (compiled from the string catalog),
  `FixtureInfo.plist`, and `FixtureModel.momd` inside
  `XcodeResources.framework` — verified on disk for Debug and
  Debug-iphonesimulator. The misses are lookup misses, not staging misses.
- **The carve-out that proves the rule.** `applyResourceBundleRewrites`
  (`XcodeBuildSystem.swift:631-656`) rewrites sources whose name matches
  `Generated*Symbols.swift` and whose body contains the generator's exact
  `ResourceBundleClass` preamble (`:666-682`), substituting
  `Bundle(path: <CODESIGNING_FOLDER_PATH>)` (`:685-693`). The wrapper path
  already rides build settings on both platforms and encodes the
  macOS-versioned vs iOS-flat layout difference. User code fails every
  filter by construction.
- **Wrapper layout differs per platform.** macOS: versioned bundle,
  `CODESIGNING_FOLDER_PATH` ends in `.framework/Versions/A`. iOS: flat
  bundle. Any fix must use the setting verbatim rather than assume a
  layout.

## Design: an agent-side `bundleForClass:` fallback

Rewriting arbitrary user sources would generalize the carve-out but is
brittle text surgery on code we do not control (arbitrary token names,
arbitrary lookup spellings — `Bundle(for:)`, `Bundle(identifier:)`,
`.main`). The durable seam is where resolution happens: Foundation's
`+[NSBundle bundleForClass:]` in the agent process.

Rule: when the daemon knows the target's wrapper path, the agent installs a
`bundleForClass:` hook. The hook calls the original; if the original
resolved to the agent's own bundle **and** the class carries no image
identity, it returns the wrapper bundle instead. Classes from real images —
the agent's own, dlopen'd dependency frameworks (B04's case), system
frameworks — hit the original path unchanged.

The discriminator is `class_getImageName(cls) == NULL`, **not** `dladdr`.
Adversarial review (2026-07-21, native experiments) showed `dladdr` on a
class pointer is placement-based nearest-symbol lookup: in a Swift process
it attributes runtime-allocated class metadata — and even real system
classes — to `libswiftCore`'s allocation pool, so it cannot discriminate.
`class_getImageName` stayed NULL for imageless classes and correct for
every real class (pure Swift included). The same review verified the
metaclass swizzle fires for Swift's `Bundle(for:)` on the Xcode 26.2 SDK,
that Foundation's bundle-for-class cache sits below the swizzle (a
late-installed hook is not bypassed by earlier lookups), and that
`Bundle(path:)` on `CODESIGNING_FOLDER_PATH` serves resources for both the
versioned and flat layouts. One measurement remains before the predicate is
final: what `class_getImageName` returns for a **real ORC-materialized**
class in the agent (the review's proxy used `objc_allocateClassPair`).
Stage 1 opens with that diagnostic; if ORC stamps JIT classes with the
agent's own executable path, the predicate degrades to
`original == Bundle.main`, which accepts redirecting agent-image lookups
as the documented cost.

- **Plumbing:** `BuildContext` gains the optional wrapper path (Xcode
  targets: `CODESIGNING_FOLDER_PATH`; SPM/Bazel: nil — SwiftPM's generated
  `Bundle.module` accessor already finds the built bundle beside the
  products, proven by R02). The session passes it to the agent with the
  render request, the same route the crash-notice and setup sidecars ride.
- **Scope:** one target per session, so one wrapper per agent process at a
  time; the hook re-arms per session start.
- **What it fixes:** `Bundle(for:)` on any class in JIT-compiled target
  code — which also fixes `String(localized:bundle:)` and Core Data
  `momd` lookups made against that bundle (R03's three misses).
- **What it deliberately does not touch:** `Bundle.main` (the agent's own
  identity, used by the JIT runtime), `Bundle.module` in SPM targets
  (already correct), lookups from real dylib images.
- **Known limitation (documented, gated):** Xcode-managed SwiftPM package
  products are JIT-linked as archives (`swiftPMPackageProducts`,
  `XcodeBuildSystem.swift:907-963`), so a package's classes are imageless
  too — the hook would misdirect a package-code `Bundle(for:)` to the
  *target's* wrapper. No current matrix row exercises an Xcode target
  embedding a resource-bearing package; that row must exist before the
  combination ships. The hook installs only when a wrapper is configured
  (the Xcode path), so pure-SPM sessions (R02) are inert by construction —
  stage 1's manual pass re-runs R02 with the hook code present to prove
  it.

## Implementation stages

Stages follow the family discipline: design → adversarial review → gates
(/simplify, /code-review, unit tier, integration tier) → manual matrix
re-verification flipping rows in VERIFICATION.md.

1. **Wrapper plumbing + agent hook.** Opens with the provenance
   diagnostic: dump `class_getImageName` and `Bundle(for:)` identity for a
   real ORC-materialized class in the macOS agent, deciding the predicate
   (see Design). Then `BuildContext.resourceWrapperPath`, the
   render-request sidecar, and the `bundleForClass:` hook behind it
   (macOS agent and iOS agent app). Unit rows pin the hook's decision
   table: imageless class + wrapper → wrapper bundle; real-image class →
   original; no wrapper configured → original. Manual: **R03 flips** —
   title `Xcode resources loaded`, plist loaded, Core Data model loaded,
   color still renders, macOS and iOS; R02 re-run with the hook code
   present (must stay inert and render Spanish); B02/B03/B04 and X01/X02
   guards hold (dependency-framework classes must keep resolving to their
   own wrappers). iOS must-verifies from review: the swizzle fires in the
   agent-app process, `Bundle(path:)` on the host wrapper path resolves
   in-sim, and a JIT class's original lookup lands on the agent app's
   `Bundle.main`.
2. **Retire the text rewrite.** With the hook in place the
   `Generated*Symbols.swift` rewrite is redundant on the Xcode path —
   remove `applyResourceBundleRewrites` and its rewrite directory, keep
   the tests that pin the generated color rendering. Only after stage 1's
   flake record is clean; the rewrite is proven and the hook must earn
   the same trust first.

## Out of scope

- R01's render half (the `LC_LINKER_OPTION` autolink scan → `addDylib`):
  named future work, unchanged by this family.
- Bazel target resource bundles: no matrix row exercises them; add a row
  before designing.
- Xcode-style asset-symbol generation for SPM/Bazel targets: different
  feature, different family.
- Pinning the Xcode build to one arch (`ARCHS=<hostArch>`): named future
  work from #438; read-side capture already tolerates fat builds.

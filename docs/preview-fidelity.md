# Preview Fidelity: Traits, Project Config, and Setup Plugin

## 1. Objective

**What:** Three complementary features that give developers the fidelity of running their app with the nimbleness of SwiftUI previews — eliminating the tradeoff that forces teams to choose between fast iteration and realistic rendering.

**Why:**

Today, iOS developers choose between two bad options:

- **Run the app in the simulator** — full fidelity (Firebase initialized, authenticated, themed), but 30s+ builds, navigate 5 screens deep to reach the feature, manually reproduce state. At scale, Airbnb reports this as the dominant productivity bottleneck.
- **SwiftUI previews** — fast iteration on a single view, but crashes with SDK dependencies (Firebase, analytics, Sentry), requires mocking everything, and runs in a sandboxed process with no real app lifecycle.

Large teams work around this with **micro apps** (also called "dev apps" or "demo apps") — standalone app targets that render a single feature module with controlled mock dependencies. Airbnb's dev apps drive over 50% of all local iOS builds. Point-Free's isowords has 9 preview apps. Lyft, Uber, SoundCloud, Spotify, and Grab all use variants of this pattern.

But micro apps have a maintenance tax: separate targets, schemes, entry points, and mock setups that drift out of sync with the main app. Every team pays this tax to get isolated feature rendering.

**PreviewsMCP can eliminate this tradeoff.** Our iOS host app is a real `UIApplication` with a real app delegate, real lifecycle events, and real network access. Combined with hot-reload, single-view rendering, and MCP-driven AI iteration, PreviewsMCP already provides most of what a micro app provides — without the maintenance overhead.

The setup plugin completes the picture: it lets users provide the same mock/stub dependency layer that a micro app provides, but as a reusable framework rather than a throwaway app target. The setup target is the micro app, minus the app.

Beyond the setup plugin, two other gaps exist:
- Trait injection is limited to `colorScheme` and `dynamicTypeSize`. Teams testing localization (RTL, locale) or accessibility (Bold Text) must modify source code.
- Every MCP call and CLI invocation requires passing platform, device, traits, and quality explicitly. No project-level defaults, no way for AI agents to discover project intent.

**Target users:**
- Teams maintaining micro apps / dev apps who want to eliminate the maintenance overhead
- Apps with SDK dependencies that crash Xcode previews (Firebase, analytics, Sentry, App Center)
- Design system teams who wrap views in theme providers and mock dependency containers
- Teams testing localization (RTL languages, locale-specific formatting)
- AI agents that repeatedly call MCP tools on the same project

**Success criteria:**
- `preview_configure` accepts `locale`, `layoutDirection`, and `legibilityWeight` alongside existing traits
- `preview_variants` accepts new trait presets (e.g., `"rtl"` for right-to-left)
- A `.previewsmcp.json` in the project root supplies default values for platform, device, traits, and quality — enabling AI agents to discover project intent and reducing per-call boilerplate to zero
- A user-provided setup module conforming to `PreviewSetup` protocol can run app-level initialization once per session and wrap preview content in custom environment/theme views — replacing micro app mock setups
- `setUp()` runs once when the host app launches — completely outside the hot-reload path. SDK initialization, auth, and font registration survive dylib reloads.
- All three features compose: config file declares default traits + setup module, MCP/CLI params override config, setup module wraps content with trait overrides applied outermost

## 2. Background

### 2.1 The Xcode preview problem

Xcode previews run in a sandboxed process with no app lifecycle — no `UIApplicationDelegate`, no `didBecomeActive`, no real `UIApplication`. This causes real-world failures:

- **Firebase/analytics:** `FirebaseApp.configure()` and `Analytics.logEvent()` crash Xcode previews outright. The only workaround was `XCODE_RUNNING_FOR_PREVIEWS` environment checks, which Xcode 16.2 broke. ([firebase-ios-sdk #6552](https://github.com/firebase/firebase-ios-sdk/issues/6552), [#13603](https://github.com/firebase/firebase-ios-sdk/issues/13603))
- **Authentication:** Views depending on login state can't render real data. The ecosystem answer is "split into two views" — one pure, one stateful.
- **Custom fonts:** Registration timing issues and `Bundle.module` path bugs in the preview sandbox silently fall back to system fonts.
- **Core Data / SwiftData:** Require valid contexts. In-memory `/dev/null` stores are the standard hack.
- **Dependency injection:** Libraries like Factory and swift-dependencies exist solely to provide preview-specific mock values.

Nobody has solved "preview views as they appear in the real running app." The entire ecosystem converged on: restructure your code, mock everything.

### 2.2 The micro app pattern

Large iOS teams work around broken previews by building micro apps — standalone app targets that render a single feature module in isolation. A typical micro app (from Point-Free's isowords) is ~27 lines:

```swift
@main
struct OnboardingPreviewApp: App {
    init() {
        Styleguide.registerFonts()
    }
    var body: some Scene {
        WindowGroup {
            OnboardingView(
                store: Store(initialState: Onboarding.State(presentationStyle: .firstLaunch)) {
                    Onboarding()
                } withDependencies: {
                    $0.audioPlayer = .live(bundles: [AppClipAudioLibrary.bundle, AppAudioLibrary.bundle])
                    $0.userDefaults = .noop
                }
            )
        }
    }
}
```

The micro app imports one feature module, stubs most dependencies (`.noop`), keeps a few live (real audio), and provides a minimal app shell. It builds in under a minute (vs. 7+ minutes for the full app at SoundCloud's scale) and lets developers iterate on a single feature without navigating through the full app.

The pattern is widespread: Airbnb (~1,500 modules), Lyft (~2,000 modules), Grab (1,000+ modules), Spotify (~1,000 modules), SoundCloud, Uber, and Kickstarter all use variants of it. Tuist's "Modular Architecture" (TMA) formalizes it as a 5-target pattern per feature module (Source, Interface, Tests, Testing, Example).

**The maintenance tax is real.** Teams must maintain separate targets, schemes, and build configurations. Mock/stub implementations drift when service interfaces evolve. SoundCloud called it "cumbersome." Airbnb mitigated it with auto-generated ephemeral dev apps from their Bazel dependency graph — but most teams don't have that tooling.

### 2.3 How the setup plugin replaces micro apps

A micro app provides three things:
1. **An app shell** (AppDelegate, window, UIApplication lifecycle) — PreviewsMCP already provides this
2. **Mock/stub dependency setup** (DI container configuration, test data factories) — this is what the setup plugin does
3. **A single feature's views** — PreviewsMCP renders these from `#Preview` blocks

The setup target is the micro app's dependency layer extracted into a reusable framework. Unlike a micro app:
- It's not a separate app to maintain — PreviewsMCP provides the app shell
- It works across all preview files, not just one feature — shared setup, used everywhere
- It survives hot-reload — `setUp()` runs once, effects persist
- It's AI-accessible — MCP tools can render any preview with the full setup applied

### 2.4 Design discussion: why a target, not a loose file

We considered a zero-config approach: drop a `PreviewSetup.swift` file in your project, PreviewsMCP discovers and compiles it automatically. This eliminates adoption ceremony but has a fatal flaw: **a loose file not part of any build target gets no LSP support.** No autocomplete, no jump-to-definition, no error highlighting. You'd be coding blind — unacceptable for anything beyond a one-liner.

For LSP to work, the file must be part of a proper build target. This is the same reason micro apps are targets, not scripts. The setup target requires more ceremony than a loose file, but it provides the same development experience as any other Swift module.

The setup target's dependencies are also a factor. Common setup needs include mock service implementations, test data factories, and stub network layers — these often live in separate modules (e.g., Tuist's "Testing" target pattern). A proper target can declare these dependencies; a loose file cannot.

### 2.5 Design discussion: trait modifier ordering

Trait modifiers from `preview_configure` are applied **outside** the setup wrapper. This means explicit trait overrides always win, regardless of what the wrapper sets:

```swift
// Generated bridge code
AnyView(
    AppPreviewSetup.wrap(SwiftUI.AnyView(
        MyPreviewContent()
    ))
    .preferredColorScheme(.dark)           // ← explicit override wins
    .environment(\.locale, Locale(identifier: "ar"))
)
```

The wrapper provides sensible defaults (theme, base environment). The explicit `preview_configure` parameters override them. This matches SwiftUI's environment resolution: outermost modifiers take precedence.

### 2.6 Design discussion: async setUp and the main thread

`setUp()` is `async throws` to support real auth flows and network calls. But `@_cdecl` entry points use C calling convention and cannot be `async`. The bridge uses a semaphore:

```swift
@_cdecl("previewSetUp")
public func previewSetUp() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        try? await AppPreviewSetup.setUp()
        semaphore.signal()
    }
    semaphore.wait()
}
```

The `Task` is intentionally NOT `@MainActor` — it runs on the cooperative thread pool. This avoids deadlocking with the main thread (which may be the caller). `setUp()` implementations that need main-thread work should dispatch to it explicitly within their async context.

If `setUp()` throws, the host app logs the error and proceeds to render the preview without setup. A setUp failure message is sent back through the TCP protocol (`{"type":"setupError","message":"..."}`) so the MCP client can report it as a warning in the `preview_start` response.

## 3. Scope

### Feature A: Extended built-in traits

Add three new trait properties to `PreviewTraits`:

| Trait | Values | SwiftUI injection | Use case |
|-------|--------|-------------------|----------|
| `locale` | BCP 47 string (e.g., `"en"`, `"ar"`, `"ja-JP"`) | `.environment(\.locale, Locale(identifier: value))` | Localization testing, number/date formatting |
| `layoutDirection` | `"leftToRight"`, `"rightToLeft"` | `.environment(\.layoutDirection, .leftToRight)` | RTL layout testing |
| `legibilityWeight` | `"regular"`, `"bold"` | `.environment(\.legibilityWeight, .regular)` | Bold Text accessibility |

**Design decisions:**
- `locale` is an open string — not validated against a fixed list, since `Locale(identifier:)` accepts any string. The spec is honest about this: invalid locales produce a `Locale` object that returns empty strings for most properties, but won't crash. Document this behavior.
- `layoutDirection` and `legibilityWeight` are closed enums with known valid values
- New traits use `.environment(\.key, value)` rather than dedicated modifiers — this is how SwiftUI injects these values
- Variant presets: `"rtl"` maps to `layoutDirection: "rightToLeft"`, `"ltr"` maps to `layoutDirection: "leftToRight"`, `"boldText"` maps to `legibilityWeight: "bold"`. Locale strings (e.g., `"ar"`) are NOT presets — they're passed as JSON variant objects: `{"locale":"ar","label":"arabic"}`

### Feature B: Project config file

A `.previewsmcp.json` file at the project root that sets defaults for all CLI commands and MCP tool calls.

```json
{
  "platform": "ios",
  "device": "iPhone 16 Pro",
  "traits": {
    "colorScheme": "light",
    "dynamicTypeSize": "large",
    "locale": "en"
  },
  "quality": 0.9,
  "setup": {
    "moduleName": "MyAppPreviewSetup",
    "typeName": "AppPreviewSetup"
  }
}
```

**Resolution order** (highest priority wins):
1. Explicit MCP/CLI parameter
2. `.previewsmcp.json` values
3. Built-in defaults (no traits, macOS platform, quality 0.8)

**Discovery:** Walk up from the source file directory to find `.previewsmcp.json`. Stop at the first one found. Cache per session (not per compile).

**All fields are optional.** A minimal config could be just `{ "platform": "ios" }`.

**Value for AI agents:** The config file's primary value isn't reducing keystrokes (AI agents don't care about boilerplate). It's **project intent** — the AI agent knows "this is an iOS project targeting iPhone 16 Pro with dark mode defaults" without inferring it from the codebase. Fewer wrong decisions, better first-try results.

**Config `device` field:** Accepts either a device name (e.g., `"iPhone 16 Pro"`) or a UDID. Names are resolved to UDIDs via the simulator list at session start.

### Feature C: Preview setup plugin

A protocol-based system for user-provided app-level setup and view wrapping. The setup target replaces micro apps: it provides the same mock/stub dependency layer, but as a reusable framework instead of a throwaway app target.

**Two concerns, two lifecycles:**

| Method | When it runs | Survives hot-reload? | Use case |
|--------|-------------|---------------------|----------|
| `setUp()` | Once per session, before the first preview renders | Yes — side effects persist in the host process | Firebase init, auth tokens, font registration, DI container setup, mock service registration |
| `wrap(_:)` | Every dylib load (every structural recompile) | N/A — runs fresh each time | Theme providers, custom environment values, navigation containers |

**What we ship:** A new SPM library product `PreviewsSetupKit` containing the `PreviewSetup` protocol.

```swift
// Sources/PreviewsSetupKit/PreviewSetup.swift
import SwiftUI

/// Conform to this protocol in a dedicated target to customize
/// how PreviewsMCP renders your previews.
///
/// The setup target replaces micro apps / dev apps: it provides the same
/// mock dependency setup and theme wrapping, but PreviewsMCP provides the
/// app shell, hot-reload, and rendering infrastructure.
///
/// `setUp()` runs once when the host app launches — before any preview
/// dylib is loaded. It runs in a real UIApplication process (iOS) or
/// NSApplication process (macOS) with full app lifecycle. Use it for SDK
/// initialization, authentication, font registration, DI container setup,
/// and mock service registration. It is completely outside the hot-reload
/// path. Users can check `#if os(iOS)` for platform-specific SDK init.
///
/// `wrap(_:)` runs on every preview render (each structural recompile).
/// Use it for theme providers, custom environment values, and view-level
/// setup that must surround every preview.
///
/// AnyView is required because the view type must be erased across the
/// dynamic library boundary.
public protocol PreviewSetup {
    /// Called once per session before the first preview renders.
    /// Async to support real auth flows and network calls.
    /// If this throws, the preview renders without setup and the
    /// error is reported as a warning to the MCP client.
    static func setUp() async throws

    /// Wraps every preview view. Called on each dylib load.
    /// Trait modifiers from preview_configure are applied OUTSIDE
    /// this wrapper, so explicit overrides always take precedence.
    static func wrap(_ content: AnyView) -> AnyView
}

extension PreviewSetup {
    public static func setUp() async throws {}
    public static func wrap(_ content: AnyView) -> AnyView { content }
}
```

**How users adopt it:**

1. Add a target to their `Package.swift` (or Xcode project):
```swift
.target(
    name: "MyAppPreviewSetup",
    dependencies: [
        "MyApp",
        "MyAppTesting",  // mock services, test data factories
        .product(name: "PreviewsSetupKit", package: "PreviewsMCP"),
    ]
)
```

2. Write the setup type — same dependency injection you'd write for a micro app:
```swift
import PreviewsSetupKit
import MyApp
import MyAppTesting  // mock services from your Testing target

struct AppPreviewSetup: PreviewSetup {
    static func setUp() async throws {
        // SDK initialization — runs once, persists across reloads
        FirebaseApp.configure()
        FontManager.registerCustomFonts()

        // DI container — same setup as a micro app
        Container.shared.register(NetworkService.self) { MockNetworkService() }
        Container.shared.register(AuthService.self) { MockAuthService.loggedIn() }

        // Or: real auth against a dev server
        let token = try await AuthService.signIn(
            email: "preview@example.com",
            password: ProcessInfo.processInfo.environment["PREVIEW_PASSWORD"] ?? ""
        )
        SessionManager.shared.setToken(token)
    }

    static func wrap(_ content: AnyView) -> AnyView {
        AnyView(
            content
                .environment(\.theme, AppTheme.default)
                .tint(.brand)
        )
    }
}
```

3. Point `.previewsmcp.json` at it:
```json
{
  "setup": {
    "moduleName": "MyAppPreviewSetup",
    "typeName": "AppPreviewSetup"
  }
}
```

**Comparison with a micro app:**

| Aspect | Micro app | PreviewsMCP + setup target |
|--------|-----------|---------------------------|
| App shell | You maintain it (AppDelegate, window, nav) | PreviewsMCP provides it |
| Mock dependencies | In the micro app's entry point | In the setup target's `setUp()` |
| Theme wrapping | In the micro app's root view | In the setup target's `wrap()` |
| Hot-reload | No — full rebuild required | Yes — literal and structural |
| Covers all features | One micro app per feature | One setup target for all previews |
| Maintenance | Drifts out of sync, separate schemes | Single target, reusable across files |
| AI integration | None | Full MCP tooling (snapshot, variants, touch, inspect) |

**How it works at runtime:**

The setup plugin uses two separate `@_cdecl` entry points in the generated dylib, called at different points in the host app lifecycle:

```
Host app launches
  → dlopen(first dylib)
  → dlsym("previewSetUp")      → call once, await completion
  → dlsym("createPreviewView") → call → render first preview
  
Hot-reload (literal-only change):
  → DesignTimeStore update      → SwiftUI re-renders (no dylib load, no setUp, no wrap)

Hot-reload (structural change):
  → dlopen(new dylib)
  → dlsym("createPreviewView") → call → re-render (setUp is NOT called again)
```

- The build system (SPM/Xcode/Bazel) builds the setup target alongside the main target. PreviewsMCP tells the build system to include it — the setup target's `.swiftmodule` becomes available on the import search path.
- `BridgeGenerator` generates two entry points: `previewSetUp` (calls `SetupType.setUp()`) and `createPreviewView` (calls `SetupType.wrap()`).
- The host app (both macOS and iOS) tracks a `hasCalledSetUp` flag. On first dylib load, it checks for the `previewSetUp` symbol and calls it. On subsequent dylib loads, it skips directly to `createPreviewView`.
- Old dylibs are retained (never `dlclose`'d) — this is existing behavior. The side effects of `setUp()` (registered fonts, auth tokens, initialized SDKs, mock service registrations) persist in the host process across all subsequent dylib loads.
- The user's main app target does NOT depend on `PreviewsSetupKit` — only the setup target does. No dev-tool leakage into production.

**Generated bridge code (example):**

```swift
import SwiftUI
import UIKit
import MyAppPreviewSetup

// Called once by host app on first dylib load
@_cdecl("previewSetUp")
public func previewSetUp() {
    let semaphore = DispatchSemaphore(value: 0)
    Task {
        try? await AppPreviewSetup.setUp()
        semaphore.signal()
    }
    semaphore.wait()
}

// Called on every dylib load (initial + each structural reload)
@_cdecl("createPreviewView")
public func createPreviewView() -> UnsafeMutableRawPointer {
    let innerView = SwiftUI.AnyView(
        MyPreviewContent()
    )
    let wrappedView = AppPreviewSetup.wrap(innerView)
    let view = SwiftUI.AnyView(
        wrappedView
            .preferredColorScheme(.dark)
            .environment(\.locale, Locale(identifier: "ar"))
    )
    let hostingController = UIHostingController(rootView: view)
    return Unmanaged.passRetained(hostingController).toOpaque()
}
```

**Trait modifiers are applied OUTSIDE the wrap** so explicit `preview_configure` overrides always take precedence over whatever the wrapper sets.

### Out of scope

- Custom macro names (#9 — closed) — users should use `#Preview` or `PreviewProvider`. Custom macros expand at compile time and are invisible to source-level parsing.
- Custom host app templates — the setup plugin covers the same use cases (SDK init, auth, DI) without requiring users to maintain a full host app.
- GUI config editor
- Config file schema validation tooling (JSON Schema for IDE support is a nice-to-have but not v1)
- Size class traits (`horizontalSizeClass`, `verticalSizeClass`) — useful but device selection already implicitly sets these. Consider for a future trait expansion.
- `accessibilityReduceMotion` — read-only in SwiftUI's environment (cannot be overridden via `.environment()`). Requires different injection mechanism. Consider for future work.

## 4. Design

### 4.1 PreviewTraits changes

```swift
public struct PreviewTraits: Sendable, Equatable {
    public var colorScheme: String?
    public var dynamicTypeSize: String?
    public var locale: String?            // NEW
    public var layoutDirection: String?   // NEW
    public var legibilityWeight: String?  // NEW
}
```

**Validation:**
- `locale`: Not validated against a fixed list. `Locale(identifier:)` accepts any string. Document that invalid locales produce a `Locale` with empty properties but won't crash.
- `layoutDirection`: Must be `"leftToRight"` or `"rightToLeft"`.
- `legibilityWeight`: Must be `"regular"` or `"bold"`.

**Merge behavior:** Same as existing — non-nil values in `other` overwrite `self`.

**Clearing traits:** Pass an empty string (`""`) for any trait to clear it. This resolves to `nil` internally, removing the trait modifier from the generated bridge code. Necessary because merge-only semantics otherwise make it impossible to unset a trait once configured.

**Variant presets:** Add `"rtl"`, `"ltr"`, `"boldText"` as preset names in `fromPreset()`. Do NOT add locale strings as presets (too many, collision risk with future presets). Locales go through JSON variant objects.

**`traitModifiers()` output (example with all traits set):**
```swift
.preferredColorScheme(.dark)
.dynamicTypeSize(.large)
.environment(\.locale, Locale(identifier: "ar"))
.environment(\.layoutDirection, .rightToLeft)
.environment(\.legibilityWeight, .bold)
```

### 4.2 ProjectConfig

New type in PreviewsCore:

```swift
public struct ProjectConfig: Sendable, Codable {
    public var platform: String?
    public var device: String?
    public var traits: TraitsConfig?
    public var quality: Double?
    public var setup: SetupConfig?

    public struct TraitsConfig: Sendable, Codable {
        public var colorScheme: String?
        public var dynamicTypeSize: String?
        public var locale: String?
        public var layoutDirection: String?
        public var legibilityWeight: String?
    }

    public struct SetupConfig: Sendable, Codable {
        public var moduleName: String
        public var typeName: String
    }
}
```

**Loading:**
```swift
public enum ProjectConfigLoader {
    public static func find(from directory: URL) -> ProjectConfig? {
        var dir = directory
        while dir.path != "/" {
            let configFile = dir.appendingPathComponent(".previewsmcp.json")
            if FileManager.default.fileExists(atPath: configFile.path),
               let data = try? Data(contentsOf: configFile),
               let config = try? JSONDecoder().decode(ProjectConfig.self, from: data) {
                return config
            }
            dir = dir.deletingLastPathComponent()
        }
        return nil
    }
}
```

**Where config is applied:**

- **MCP server:** Load config once in `handlePreviewStart()` (or lazily on first tool call). Store on the `MCPServer` actor. Apply defaults before processing each tool call.
- **CLI commands:** Load config in each command's `run()` method based on the source file path. Apply defaults before creating sessions.
- **Precedence helper:**
```swift
// Example: resolving platform
let platform = explicitParam ?? config?.platform ?? "macos"
```

### 4.3 BridgeGenerator changes for setup plugin

`BridgeGenerator` methods gain two new optional parameters:

```swift
public static func generateCombinedSource(
    originalSource: String,
    closureBody: String,
    previewIndex: Int = 0,
    entryPoint: String = "createPreviewView",
    platform: PreviewPlatform = .macOS,
    traits: PreviewTraits = PreviewTraits(),
    setupModule: String? = nil,     // NEW — module to import
    setupType: String? = nil        // NEW — type name to call
) -> (source: String, literals: [LiteralEntry])
```

When `setupModule` and `setupType` are both non-nil, the generated bridge code:
1. Adds `import <setupModule>` to imports
2. Generates a `@_cdecl("previewSetUp")` entry point that calls `<SetupType>.setUp()` via semaphore bridge
3. In `createPreviewView`: wraps the view with `<SetupType>.wrap()`, then applies trait modifiers outermost

When either is nil, bridge generation is unchanged — no `previewSetUp` entry point, no wrapping.

Same parameters added to `generateBridgeOnlySource()` and `generateOverlaySource()`.

### 4.4 Host app changes for setUp lifecycle

Both host apps (macOS `HostApp.swift` and iOS `IOSHostAppSource.swift`) gain a `hasCalledSetUp: Bool` flag:

**iOS host app (IOSHostAppSource.swift):**
```swift
private var hasCalledSetUp = false

private func loadPreview(dylibPath: String) {
    guard let handle = dlopen(dylibPath, RTLD_NOW | RTLD_GLOBAL) else { ... }

    // Call setUp exactly once on first dylib load
    if !hasCalledSetUp {
        if let setUpSym = dlsym(handle, "previewSetUp") {
            typealias SetUpFunc = @convention(c) () -> Void
            let setUpFn = unsafeBitCast(setUpSym, to: SetUpFunc.self)
            setUpFn()
        }
        hasCalledSetUp = true
    }

    // Create preview view (every load)
    guard let sym = dlsym(handle, "createPreviewView") else { ... }
    // ... existing view creation code ...
}
```

**setUp error reporting:** If `previewSetUp` fails, the error is sent back through the TCP protocol as `{"type":"setupError","message":"..."}`. The MCP `preview_start` response includes a warning: "Setup failed: <error>. Preview rendered without setup." This ensures errors are visible to AI agents and MCP clients, not buried in stderr.

**macOS host app (`HostApp.swift`):** Same pattern — check `hasCalledSetUp` flag on first dylib load, call `previewSetUp` if the symbol exists.

### 4.5 Build system integration for setup target

The setup target must be built before the preview bridge can import it. This integrates with the existing `BuildContext`:

```swift
public struct BuildContext: Sendable {
    // ... existing fields ...
    public let setupModuleName: String?       // NEW
    public let setupCompilerFlags: [String]   // NEW — -I flags for setup module
}
```

The build system (SPMBuildSystem, XcodeBuildSystem, BazelBuildSystem) is responsible for:
1. Detecting the setup target from config
2. Building it alongside the main target
3. Providing its `.swiftmodule` path in `setupCompilerFlags`

For SPM this means adding `--target MyAppPreviewSetup` to the build command. For Xcode, adding the scheme. For Bazel, adding the target to the build command.

### 4.6 Standalone mode

In standalone mode (no build system), setup plugin is not supported — there's no module system to import from. The config file's `setup` section is ignored with a warning in the `preview_start` MCP response (not just stderr). Extended traits and other config fields still apply.

### 4.7 MCP tool schema changes

**`preview_start`** — add new trait parameters:
```json
{
  "locale": { "type": "string", "description": "BCP 47 locale identifier (e.g., 'en', 'ar', 'ja-JP')" },
  "layoutDirection": { "type": "string", "enum": ["leftToRight", "rightToLeft"] },
  "legibilityWeight": { "type": "string", "enum": ["regular", "bold"] }
}
```

**`preview_configure`** — same new parameters. Pass `""` (empty string) to clear a previously set trait.

**`preview_variants`** — no schema change. Variants already accept JSON objects, so `{"locale":"ar","layoutDirection":"rightToLeft","label":"arabic-rtl"}` works once `PreviewTraits` supports the new fields.

**No new tool parameters for config file.** Config is auto-discovered. If a future need arises for overriding config path, add a `configPath` parameter then.

**No new tool parameters for setup plugin.** Setup is declared in config. The MCP server reads it from config and passes it to the build/bridge pipeline.

### 4.8 CLI changes

**New flags on `run`, `snapshot`, `variants`:**
```
--locale <identifier>         Locale (e.g., 'en', 'ar', 'ja-JP')
--layout-direction <dir>      Layout direction: 'leftToRight' or 'rightToLeft'
--legibility-weight <weight>  Legibility weight: 'regular' or 'bold'
--config <path>               Path to .previewsmcp.json (overrides auto-discovery)
```

## 5. Project Structure

### New files

| File | Module | Purpose |
|------|--------|---------|
| `Sources/PreviewsSetupKit/PreviewSetup.swift` | PreviewsSetupKit | Protocol + default implementations |
| `Sources/PreviewsCore/ProjectConfig.swift` | PreviewsCore | `ProjectConfig`, `ProjectConfigLoader` |

### Modified files

| File | Change |
|------|--------|
| `Package.swift` | Add `PreviewsSetupKit` library product and target |
| `Sources/PreviewsCore/PreviewTraits.swift` | Add `locale`, `layoutDirection`, `legibilityWeight` properties, validation, presets, merge logic, empty-string clearing |
| `Sources/PreviewsCore/BridgeGenerator.swift` | Add `setupModule`/`setupType` params, generate `previewSetUp` entry point, extend `traitModifiers()` with new traits, apply traits outside wrap |
| `Sources/PreviewsCore/PreviewSession.swift` | Thread `setupModule`/`setupType` to BridgeGenerator |
| `Sources/PreviewsCore/BuildContext.swift` | Add `setupModuleName`, `setupCompilerFlags` |
| `Sources/PreviewsCLI/MCPServer.swift` | Load config, add new trait params to tool schemas, apply config defaults |
| `Sources/PreviewsCLI/RunCommand.swift` | Add new CLI flags, load config, apply defaults |
| `Sources/PreviewsCLI/SnapshotCommand.swift` | Add new CLI flags, load config, apply defaults |
| `Sources/PreviewsCLI/VariantsCommand.swift` | Load config, apply defaults |
| `Sources/PreviewsIOS/IOSPreviewSession.swift` | Thread setup params through to PreviewSession |
| `Sources/PreviewsIOS/IOSHostAppSource.swift` | Add `hasCalledSetUp` flag, call `previewSetUp` on first dylib load only, send setUp errors via TCP |
| `Sources/PreviewsMacOS/HostApp.swift` | Add `hasCalledSetUp` flag, call `previewSetUp` on first dylib load only |

## 6. Code Style

Follows existing project conventions:

```swift
// PreviewTraits — new validation follows existing pattern
public static let validLayoutDirections: Set<String> = ["leftToRight", "rightToLeft"]
public static let validLegibilityWeights: Set<String> = ["regular", "bold"]

// Config loading — no throwing; missing/malformed config is nil
public static func find(from directory: URL) -> ProjectConfig?

// BridgeGenerator — trait modifiers follow existing pattern
if let locale = traits.locale {
    mods += "\n            .environment(\\.locale, Locale(identifier: \"\(locale)\"))"
}
```

- Swift 6.0 strict concurrency — all new types are `Sendable`
- `ProjectConfig` is `Codable` for JSON decoding
- `PreviewsSetupKit` has zero dependencies (only imports SwiftUI)
- No new external dependencies anywhere

## 7. Testing Strategy

### Unit tests

**PreviewTraits (extended):**
- Validate new trait values (valid locale, invalid locale, valid/invalid layoutDirection, legibilityWeight)
- Merge behavior with new fields
- Empty string clears a trait (resolves to nil)
- New presets (`"rtl"`, `"ltr"`, `"boldText"`) resolve correctly
- JSON variant parsing with new trait fields
- `isEmpty` returns true only when all five fields are nil

**ProjectConfig:**
- Decode valid JSON with all fields
- Decode minimal JSON (single field)
- Decode JSON with unknown fields (forward-compatible — ignores them)
- `find(from:)` walks up directories correctly
- `find(from:)` returns nil when no config exists
- Precedence: explicit param > config > default

**BridgeGenerator (extended):**
- `traitModifiers()` outputs correct `.environment()` calls for new traits
- Generated source includes `import SetupModule` when setup is configured
- Generated source has separate `@_cdecl("previewSetUp")` calling `SetupType.setUp()`
- Generated `createPreviewView` calls `SetupType.wrap()` but NOT `SetupType.setUp()`
- Trait modifiers are applied outside wrap in generated code
- Generated source is unchanged when setup is nil (no `previewSetUp` entry point, no wrapping)

### Integration tests

- Round-trip: create `.previewsmcp.json` in test fixture, run `preview_start`, verify traits applied
- Setup plugin: add test setup target to SPM example, verify setUp() runs on first load and wrap() runs on every load
- setUp persistence: after initial load, trigger a structural hot-reload, verify setUp() is NOT called again (check via a side effect like a file write or counter)
- setUp error handling: make setUp() throw, verify preview still renders and error is reported in MCP response
- Variant capture with new traits: `{"locale":"ar","layoutDirection":"rightToLeft"}` produces correct snapshot
- Variant capture with setup: verify setUp() runs once across all variant captures, not once per variant

## 8. Boundaries

### Always do
- Validate all trait values before passing to BridgeGenerator
- Respect precedence: explicit param > config > default
- Make config loading non-fatal — malformed config logs a warning and falls back to defaults
- Keep `PreviewsSetupKit` zero-dependency (SwiftUI only)
- Apply trait modifiers outside the setup wrap (explicit overrides take precedence)
- Report setUp errors through TCP and MCP response, not just stderr

### Ask first
- Whether to add a `preview_config` MCP tool that returns the resolved config for debugging
- Whether config should support glob patterns for per-file trait overrides
- Whether to add a `previewsmcp setup init` CLI command that scaffolds the setup target

### Never do
- Add `PreviewsSetupKit` as a dependency of the user's production target — it's dev-only
- Make config file required — all fields optional, missing config is fine
- Add locale strings as variant presets — too many, collision risk
- Break existing behavior — all new parameters are optional with nil defaults
- Use `@MainActor` in the `previewSetUp` semaphore bridge — it will deadlock

## 9. Resolved Questions

- **Config file name:** `.previewsmcp.json` — dot-prefix matches convention for tool configs (`.swiftformat`, `.swiftlint.yml`).
- **Config validation:** Deferred — validate when traits are applied, not when config is parsed. `Codable` decoding catches structural issues; trait values are validated at use site for consistent behavior with and without config.
- **setUp() error handling:** Proceed with warning — if `setUp()` throws, the host app logs the error and renders the preview without setup. Error is reported via TCP and included in MCP `preview_start` response.
- **macOS setUp():** Document it — `setUp()` runs in an `NSApplication` on macOS and a `UIApplication` on iOS. Users can check `#if os(iOS)` in their setUp for platform-specific SDK init. macOS setUp is still useful for fonts, environment values, and design system setup.
- **`setUp()` lifecycle:** Runs once per session via separate `@_cdecl("previewSetUp")` entry point. Host app calls it on first dylib load only. Completely outside the hot-reload path.
- **Setup + hot-reload:** Literal-only changes don't reload dylibs, so neither `setUp()` nor `wrap()` re-runs. Structural changes reload the dylib but only call `createPreviewView` (which calls `wrap()`). `setUp()` side effects persist in the host process.
- **Setup + variants:** Each variant recompiles and calls `createPreviewView` (triggering `wrap()`), but `setUp()` is NOT re-invoked. SDK init, auth, and fonts persist across all variant captures.
- **Async setUp():** `setUp()` is `async throws`. The `@_cdecl` entry point bridges via `Task` (NOT `@MainActor`) + `DispatchSemaphore` to avoid deadlocking the main thread.
- **Trait modifier ordering:** Traits applied outside wrap so explicit `preview_configure` overrides always win over wrapper defaults.
- **Config key naming:** `quality` (not `snapshotQuality`) to match MCP/CLI naming. `setup.moduleName`/`setup.typeName` (not `target`/`type`) for clarity.
- **Locale validation:** Not validated against a fixed list. Documented that `Locale(identifier:)` accepts any string; invalid locales won't crash but produce empty properties.
- **Trait clearing:** Empty string `""` clears a trait, resolving to `nil` internally.
- **Loose file vs. target:** Target required for LSP support (autocomplete, jump-to-definition, error highlighting). A loose file gets no tooling — unacceptable for non-trivial setup code.
- **Custom macros (#9):** Closed. Custom macros expand at compile time and are invisible to source-level parsing.

# Setup Plugin

`PreviewsSetupKit` provides a protocol for app-level initialization and view wrapping — replacing micro apps / dev apps that teams maintain for isolated feature testing. PreviewsMCP runs a real app process (`UIApplication` on iOS, `NSApplication` on macOS), so SDK initialization, authentication, and font registration work normally.

## How it works

| Method | When | Survives hot-reload? | Use case |
|--------|------|---------------------|----------|
| `setUp()` | Once per session, before first preview | Yes | Firebase init, auth, fonts, DI container |
| `wrap(_:)` | Every dylib load | N/A | Theme providers, environment values |

`setUp()` is `async throws` and runs completely outside the hot-reload path. If it throws, the preview renders without setup and the error is reported as a warning. Trait modifiers from `preview_configure` are applied outside the wrapper, so explicit overrides always take precedence.

## Creating a setup package

Your app target does not depend on PreviewsMCP. Instead, create a separate standalone package for preview setup:

```
PreviewSetup/
├── Package.swift
└── Sources/MyAppPreviewSetup/Setup.swift
```

```swift
// PreviewSetup/Package.swift
import PackageDescription

let package = Package(
    name: "PreviewSetup",
    platforms: [.macOS(.v14), .iOS(.v17)],
    dependencies: [
        .package(url: "https://github.com/obj-p/PreviewsMCP.git", from: "..."),
    ],
    targets: [
        .target(
            name: "MyAppPreviewSetup",
            dependencies: [
                .product(name: "PreviewsSetupKit", package: "PreviewsMCP"),
            ]
        ),
    ]
)
```

## Implementing the protocol

```swift
import PreviewsSetupKit
import SwiftUI

public struct AppPreviewSetup: PreviewSetup {
    public static func setUp() async throws {
        FirebaseApp.configure()
        FontManager.registerCustomFonts()
        // DI container registration, mock service setup, etc.
    }

    public static func wrap(_ content: AnyView) -> AnyView {
        AnyView(content.environment(\.theme, AppTheme.default))
    }
}
```

Both methods have default (no-op) implementations, so you only need to implement the ones you use.

## Wiring it up

Point your `.previewsmcp.json` at the setup target:

```json
{
  "setup": {
    "moduleName": "MyAppPreviewSetup",
    "typeName": "AppPreviewSetup",
    "packagePath": "PreviewSetup"
  }
}
```

| Field | Description |
|-------|-------------|
| `moduleName` | The Swift module name of your setup target |
| `typeName` | The type conforming to `PreviewSetup` |
| `packagePath` | Path to the setup package, relative to the config file |

PreviewsMCP builds the setup package independently via `SetupBuilder` — your app's `Package.swift` is untouched. The config is auto-discovered by walking up from the source file directory, or specified explicitly with `--config`.

## Build systems

Works across SPM, Xcode projects (`.xcodeproj` / `.xcworkspace`), and Bazel. Standalone mode (no build system) ignores the setup config with a warning.

## See also

- [`PreviewSetup` protocol source](../Sources/PreviewsSetupKit/PreviewSetup.swift)
- [Architecture overview](architecture.md)
